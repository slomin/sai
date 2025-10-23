mod app;
mod cli;
mod lm;
mod spinner;

use anyhow::Result;
use clap::Parser;

use crate::app::{App, AppExit};
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
    let app = App::new(args, client);

    if let AppExit::Print(output) = app.run().await? {
        println!("{output}");
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
