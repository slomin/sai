use clap::{Parser, builder::ValueHint};

/// Command-line assistant powered by Ratatui.
#[derive(Debug, Parser, Clone)]
#[command(author, version, about = "Ratatui-based assistant CLI")]
pub struct CliArgs {
    /// Override the chat completion endpoint.
    #[arg(
        long,
        env = "SAI_LM_ENDPOINT",
        default_value = "http://localhost:1234/v1/chat/completions",
        value_hint = ValueHint::Url
    )]
    pub endpoint: String,

    /// Model identifier to request from the endpoint.
    #[arg(long, env = "SAI_LM_MODEL", default_value = "qwen3-vl-4b-instruct-mlx")]
    pub model: String,

    /// Optional API key or bearer token for the endpoint.
    #[arg(long, env = "SAI_LM_API_KEY", value_hint = ValueHint::Other)]
    pub api_key: Option<String>,

    /// Disable clipboard integration.
    #[arg(long, env = "RAI_NO_CLIPBOARD")]
    pub no_clipboard: bool,

    /// Custom system prompt; defaults to built-in JSON structured instructions.
    #[arg(long, env = "RAI_SYSTEM_PROMPT")]
    pub system_prompt: Option<String>,

    /// Configure tracing log filter (e.g. `debug`, `info,sai=trace`).
    #[arg(long, env = "RAI_LOG", value_hint = ValueHint::Other)]
    pub log_filter: Option<String>,

    /// Prompt to send to the model. If omitted, rai reads from stdin.
    #[arg(value_hint = ValueHint::CommandString, trailing_var_arg=true)]
    pub prompt: Vec<String>,
}
