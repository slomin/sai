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

const (
	defaultTemperature     = 0.2
	defaultChatTemperature = 0.5
)

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

// ChatMessage represents a single message exchanged with the language model.
type ChatMessage struct {
	Role    string
	Content string
}

// Complete issues the request and parses the structured response.
func (c *Client) Complete(ctx context.Context, systemPrompt, userPrompt string) (CompletionResult, error) {
	messages := buildMessages(systemPrompt, []ChatMessage{{Role: "user", Content: userPrompt}})
	parsed, rawBody, err := c.send(ctx, messages, defaultTemperature, false)
	if err != nil {
		return CompletionResult{}, err
	}

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

// Chat issues a conversational request and returns the assistant reply text.
func (c *Client) Chat(ctx context.Context, systemPrompt string, history []ChatMessage) (string, error) {
	messages := buildMessages(systemPrompt, history)
	parsed, _, err := c.send(ctx, messages, defaultChatTemperature, false)
	if err != nil {
		return "", err
	}

	if len(parsed.Choices) == 0 {
		return "", fmt.Errorf("response contained no choices")
	}

	return strings.TrimSpace(parsed.Choices[0].Message.Content), nil
}

func buildMessages(systemPrompt string, history []ChatMessage) []chatMessage {
	messages := make([]chatMessage, 0, len(history)+1)
	messages = append(messages, chatMessage{Role: "system", Content: systemPrompt})
	for _, entry := range history {
		messages = append(messages, chatMessage{Role: entry.Role, Content: entry.Content})
	}
	return messages
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
	Stream      bool          `json:"stream,omitempty"`
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
	Delta   deltaResponse       `json:"delta"`
}

type chatMessageResponse struct {
	Content string `json:"content"`
}

type deltaResponse struct {
	Content string `json:"content"`
}

type structuredPayload struct {
	Explanation        string `json:"explanation"`
	RecommendedCommand string `json:"recommended_command"`
}

func (c *Client) send(ctx context.Context, messages []chatMessage, temperature float32, stream bool) (chatResponse, []byte, error) {
	reqBody := chatRequest{
		Model:       c.model,
		Messages:    messages,
		Temperature: temperature,
		Stream:      stream,
	}

	body, err := json.Marshal(reqBody)
	if err != nil {
		return chatResponse{}, nil, fmt.Errorf("encode request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(body))
	if err != nil {
		return chatResponse{}, nil, fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if c.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.apiKey)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return chatResponse{}, nil, fmt.Errorf("send request: %w", err)
	}
	defer resp.Body.Close()

	rawBody, err := ioReadAll(resp.Body)
	if err != nil {
		return chatResponse{}, nil, fmt.Errorf("read response body: %w", err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return chatResponse{}, nil, fmt.Errorf("endpoint returned %s: %s", resp.Status, rawBody)
	}

	var parsed chatResponse
	if err := json.Unmarshal(rawBody, &parsed); err != nil {
		return chatResponse{}, nil, fmt.Errorf("decode response: %w", err)
	}

	logRawResponse(rawBody)

	return parsed, rawBody, nil
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
