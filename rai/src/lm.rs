use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, anyhow};
use reqwest::{Client, header};
use serde::{Deserialize, Serialize};
use tracing::debug;

#[derive(Clone)]
pub struct LmClient {
    inner: Arc<LmClientInner>,
}

struct LmClientInner {
    client: Client,
    endpoint: String,
    model: String,
}

impl LmClient {
    pub fn new(endpoint: String, model: String, api_key: Option<String>) -> Result<Self> {
        let mut headers = header::HeaderMap::new();
        headers.insert(
            header::CONTENT_TYPE,
            header::HeaderValue::from_static("application/json"),
        );

        if let Some(token) = api_key.as_ref() {
            let value = format!("Bearer {token}");
            headers.insert(
                header::AUTHORIZATION,
                header::HeaderValue::from_str(&value)
                    .map_err(|_| anyhow!("invalid API key header value"))?,
            );
        }

        let client = Client::builder()
            .default_headers(headers)
            .no_proxy()
            .timeout(Duration::from_secs(120))
            .build()
            .context("failed to build HTTP client")?;

        Ok(Self {
            inner: Arc::new(LmClientInner {
                client,
                endpoint,
                model,
            }),
        })
    }

    pub async fn complete(
        &self,
        system_prompt: &str,
        user_prompt: &str,
    ) -> Result<CompletionResult> {
        let request = ChatRequest::new(&self.inner.model, system_prompt, user_prompt);
        let response = self
            .inner
            .client
            .post(&self.inner.endpoint)
            .json(&request)
            .send()
            .await
            .context("chat completion request failed")?;

        let status = response.status();
        let body = response
            .text()
            .await
            .context("failed to read response body")?;

        if !status.is_success() {
            return Err(anyhow!("endpoint returned {status}: {body}"));
        }

        debug!("raw completion response: {body}");
        let parsed: ChatResponse =
            serde_json::from_str(&body).context("failed to deserialize completion response")?;

        let choice = parsed
            .choices
            .into_iter()
            .next()
            .ok_or_else(|| anyhow!("response contained no choices"))?;

        let content = choice.message.content.trim().to_owned();
        let structured = parse_structured(&content)
            .context("model response could not be parsed as structured JSON")?;

        Ok(CompletionResult {
            structured,
            raw_text: content,
            usage: parsed.usage,
        })
    }
}

#[derive(Debug)]
pub struct CompletionResult {
    pub structured: StructuredAnswer,
    pub raw_text: String,
    pub usage: Option<Usage>,
}

#[derive(Debug, Clone)]
pub struct StructuredAnswer {
    pub explanation: String,
    pub recommended_command: String,
}

#[derive(Serialize)]
struct ChatRequest<'a> {
    model: &'a str,
    messages: Vec<ChatMessage<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    temperature: Option<f32>,
}

#[derive(Serialize)]
struct ChatMessage<'a> {
    role: &'a str,
    content: &'a str,
}

impl<'a> ChatRequest<'a> {
    fn new(model: &'a str, system_prompt: &'a str, user_prompt: &'a str) -> Self {
        Self {
            model,
            messages: vec![
                ChatMessage {
                    role: "system",
                    content: system_prompt,
                },
                ChatMessage {
                    role: "user",
                    content: user_prompt,
                },
            ],
            temperature: Some(0.2),
        }
    }
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<ChatChoice>,
    #[serde(default)]
    usage: Option<Usage>,
}

#[derive(Deserialize)]
struct ChatChoice {
    message: ChatMessageResponse,
}

#[derive(Deserialize)]
struct ChatMessageResponse {
    content: String,
}

#[derive(Debug, Deserialize, Clone)]
pub struct Usage {
    #[serde(default)]
    pub prompt_tokens: Option<u64>,
    #[serde(default)]
    pub completion_tokens: Option<u64>,
    #[serde(default)]
    pub total_tokens: Option<u64>,
}

#[derive(Deserialize)]
struct StructuredPayload {
    #[serde(default)]
    explanation: String,
    #[serde(default)]
    recommended_command: String,
}

impl From<StructuredPayload> for StructuredAnswer {
    fn from(value: StructuredPayload) -> StructuredAnswer {
        StructuredAnswer {
            explanation: value.explanation.trim().to_owned(),
            recommended_command: value.recommended_command.trim().to_owned(),
        }
    }
}

fn parse_structured(content: &str) -> Result<StructuredAnswer> {
    let trimmed = content.trim();
    if trimmed.is_empty() {
        return Err(anyhow!("empty model response"));
    }

    if let Ok(result) = try_parse_payload(trimmed) {
        return Ok(result);
    }

    if let Some(json) = extract_json_block(trimmed) {
        if let Ok(result) = try_parse_payload(json) {
            return Ok(result);
        }
    }

    Err(anyhow!("could not locate JSON object in response"))
}

fn try_parse_payload(candidate: &str) -> Result<StructuredAnswer> {
    let payload: StructuredPayload = serde_json::from_str(candidate)?;
    Ok(payload.into())
}

fn extract_json_block(text: &str) -> Option<&str> {
    if let Some(start) = text.find('{') {
        if let Some(end) = text.rfind('}') {
            if start < end {
                return Some(text[start..=end].trim());
            }
        }
    }
    None
}
