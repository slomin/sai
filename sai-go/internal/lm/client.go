package lm

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"
)

const defaultTemperature = 0.2

// Client performs chat completion requests against the configured endpoint.
type Client struct {
	httpClient *http.Client
	endpoint   string
	model      string
	apiKey     string
}

// NewClient constructs an HTTP client with sensible defaults.
func NewClient(endpoint, model, apiKey string) (*Client, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil

	client := &http.Client{
		Timeout:   120 * time.Second,
		Transport: transport,
	}

	return &Client{
		httpClient: client,
		endpoint:   endpoint,
		model:      model,
		apiKey:     apiKey,
	}, nil
}

// StructuredAnswer mirrors the Contract returned by the backend.
type StructuredAnswer struct {
	Explanation        string
	RecommendedCommand string
}

// Usage mirrors OpenAI-style usage metadata.
type Usage struct {
	PromptTokens     *int `json:"prompt_tokens,omitempty"`
	CompletionTokens *int `json:"completion_tokens,omitempty"`
	TotalTokens      *int `json:"total_tokens,omitempty"`
}

// CompletionResult contains the structured answer and raw payload.
type CompletionResult struct {
	Structured  StructuredAnswer
	RawText     string
	RawResponse string
	Usage       *Usage
}

// Complete issues the request and parses the structured response.
func (c *Client) Complete(ctx context.Context, systemPrompt, userPrompt string) (CompletionResult, error) {
	reqBody := chatRequest{
		Model: c.model,
		Messages: []chatMessage{
			{Role: "system", Content: systemPrompt},
			{Role: "user", Content: userPrompt},
		},
		Temperature: defaultTemperature,
	}

	body, err := json.Marshal(reqBody)
	if err != nil {
		return CompletionResult{}, fmt.Errorf("encode request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(body))
	if err != nil {
		return CompletionResult{}, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if c.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.apiKey)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return CompletionResult{}, fmt.Errorf("send request: %w", err)
	}
	defer resp.Body.Close()

	rawBody, err := ioReadAll(resp.Body)
	if err != nil {
		return CompletionResult{}, fmt.Errorf("read response body: %w", err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return CompletionResult{}, fmt.Errorf("endpoint returned %s: %s", resp.Status, rawBody)
	}

	var parsed chatResponse
	if err := json.Unmarshal(rawBody, &parsed); err != nil {
		return CompletionResult{}, fmt.Errorf("decode response: %w", err)
	}

	logRawResponse(rawBody)

	if len(parsed.Choices) == 0 {
		return CompletionResult{}, fmt.Errorf("response contained no choices")
	}

	content := strings.TrimSpace(parsed.Choices[0].Message.Content)
	structured, err := parseStructured(content)
	if err != nil {
		return CompletionResult{}, fmt.Errorf("parse structured response: %w", err)
	}

	return CompletionResult{
		Structured:  structured,
		RawText:     content,
		RawResponse: string(rawBody),
		Usage:       parsed.Usage,
	}, nil
}

func parseStructured(content string) (StructuredAnswer, error) {
	trimmed := strings.TrimSpace(content)
	if trimmed == "" {
		return StructuredAnswer{}, fmt.Errorf("empty model response")
	}

	if payload, err := tryParsePayload(trimmed); err == nil {
		return payload, nil
	}

	if jsonBlock := extractJSONBlock(trimmed); jsonBlock != "" {
		if payload, err := tryParsePayload(jsonBlock); err == nil {
			return payload, nil
		}
	}

	return StructuredAnswer{}, fmt.Errorf("could not locate JSON object in response")
}

func logRawResponse(body []byte) {
	if slog.Default().Enabled(context.Background(), slog.LevelDebug) {
		slog.Debug("lm raw response", "body", string(body))
	}
}

type chatRequest struct {
	Model       string        `json:"model"`
	Messages    []chatMessage `json:"messages"`
	Temperature float32       `json:"temperature,omitempty"`
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type chatResponse struct {
	Choices []chatChoice `json:"choices"`
	Usage   *Usage       `json:"usage,omitempty"`
}

type chatChoice struct {
	Message chatMessageResponse `json:"message"`
}

type chatMessageResponse struct {
	Content string `json:"content"`
}

type structuredPayload struct {
	Explanation        string `json:"explanation"`
	RecommendedCommand string `json:"recommended_command"`
}

func tryParsePayload(candidate string) (StructuredAnswer, error) {
	var payload structuredPayload
	if err := json.Unmarshal([]byte(candidate), &payload); err != nil {
		return StructuredAnswer{}, err
	}
	return StructuredAnswer{
		Explanation:        strings.TrimSpace(payload.Explanation),
		RecommendedCommand: strings.TrimSpace(payload.RecommendedCommand),
	}, nil
}

func extractJSONBlock(text string) string {
	start := strings.IndexRune(text, '{')
	end := strings.LastIndex(text, "}")
	if start >= 0 && end > start {
		return strings.TrimSpace(text[start : end+1])
	}
	return ""
}

// ioReadAll is wrapped for unit testing and to avoid importing unnecessary
// helpers elsewhere.
var ioReadAll = func(r io.Reader) ([]byte, error) {
	return io.ReadAll(r)
}
