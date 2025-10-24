mod app;
mod cli;
mod context;
mod lm;
mod spinner;

use std::time::Instant;

use anyhow::{Result, anyhow};
use clap::Parser;
use serde_json::json;

use crate::app::{App, AppExit, initial_prompt_from_args, resolve_system_prompt};
use crate::cli::CliArgs;
use crate::context::compose_prompt;
use crate::lm::LmClient;

const REMOTE_ENDPOINT: &str = "http://192.168.1.90:8080/v1/chat/completions";
const REMOTE_MODEL: &str = "models/qwen3.gguf";

#[tokio::main]
async fn main() -> Result<()> {
    let _ = color_eyre::install();

    let mut args = CliArgs::parse();
    init_tracing(&args);

    if args.remote {
        args.endpoint = REMOTE_ENDPOINT.to_string();
        args.model = REMOTE_MODEL.to_string();
        tracing::info!("using remote llama endpoint {}", args.endpoint);
    }

    let client = LmClient::new(
        args.endpoint.clone(),
        args.model.clone(),
        args.api_key.clone(),
    )?;
    let dump_debug = args.debug;

    if args.debug {
        run_debug_once(&args, &client, true).await?;
        return Ok(());
    }

    if args.debug_performance {
        run_debug_once(&args, &client, dump_debug).await?;
        return Ok(());
    }

    let app = App::new(args, client);

    if let AppExit::Output { text } = app.run().await? {
        println!("{text}");
    }

    Ok(())
}

fn init_tracing(args: &CliArgs) {
    let filter = args
        .log_filter
        .as_ref()
        .map(String::as_str)
        .unwrap_or("info");

    let _ = tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::new(filter))
        .with_writer(std::io::stderr)
        .try_init();
}

async fn run_debug_once(args: &CliArgs, client: &LmClient, dump_debug: bool) -> Result<()> {
    let prompt = initial_prompt_from_args(args)
        .ok_or_else(|| anyhow!("prompt required for --debug-performance mode"))?;
    let system_prompt = resolve_system_prompt(args);
    let trimmed_prompt = prompt.trim().to_string();
    let composed_prompt = compose_prompt(&trimmed_prompt);

    if dump_debug {
        let request_preview = json!({
            "model": args.model,
            "messages": [
                {"role": "system", "content": system_prompt.clone()},
                {"role": "user", "content": composed_prompt.clone()},
            ],
            "temperature": 0.2,
        });
        println!("--- Request --------------------------------------------------");
        println!("{}", serde_json::to_string_pretty(&request_preview)?);
        println!();
    }

    let started = Instant::now();
    let completion = client.complete(&system_prompt, &composed_prompt).await?;
    let elapsed = started.elapsed().as_secs_f64();

    println!("Prompt: {}", trimmed_prompt);
    println!();
    println!("Explanation:");
    for line in completion.structured.explanation.trim().lines() {
        println!("  {line}");
    }
    if !completion.structured.recommended_command.trim().is_empty() {
        println!();
        println!("Recommended Command:");
        println!("  {}", completion.structured.recommended_command.trim());
    }
    println!();
    println!("[Total Response Time] {:.3}s", elapsed);

    if let Some(usage) = completion.usage {
        if let Some(total) = usage.total_tokens {
            println!("Usage: total {total} tokens");
        } else if let (Some(prompt_tokens), Some(completion_tokens)) =
            (usage.prompt_tokens, usage.completion_tokens)
        {
            println!("Usage: prompt {prompt_tokens} · completion {completion_tokens} tokens");
        }
    }

    if dump_debug {
        println!();
        println!("--- Raw Response --------------------------------------------");
        match serde_json::from_str::<serde_json::Value>(&completion.raw_response) {
            Ok(value) => println!("{}", serde_json::to_string_pretty(&value)?),
            Err(_) => println!("{}", completion.raw_response),
        }
    }

    Ok(())
}
