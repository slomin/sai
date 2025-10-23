mod app;
mod cli;
mod lm;
mod spinner;

use std::time::Instant;

use anyhow::{Result, anyhow};
use clap::Parser;

use crate::app::{App, AppExit, initial_prompt_from_args, resolve_system_prompt};
use crate::cli::CliArgs;
use crate::lm::LmClient;

#[tokio::main]
async fn main() -> Result<()> {
    let _ = color_eyre::install();

    let args = CliArgs::parse();
    init_tracing(&args);

    let client = LmClient::new(
        args.endpoint.clone(),
        args.model.clone(),
        args.api_key.clone(),
    )?;

    if args.debug_performance {
        run_debug_performance(&args, &client).await?;
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

async fn run_debug_performance(args: &CliArgs, client: &LmClient) -> Result<()> {
    let prompt = initial_prompt_from_args(args)
        .ok_or_else(|| anyhow!("prompt required for --debug-performance mode"))?;
    let system_prompt = resolve_system_prompt(args);

    let started = Instant::now();
    let completion = client.complete(&system_prompt, prompt.trim()).await?;
    let elapsed = started.elapsed().as_secs_f64();

    println!("Prompt: {}", prompt.trim());
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

    Ok(())
}
