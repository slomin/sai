package lm

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	defaultTemperature     = 0.2
	defaultChatTemperature = 0.5
)

var ErrStreamUnsupported = errors.New("lm streaming unsupported")
var ErrEndpointUnreachable = errors.New("lm: endpoint unreachable")

// Client performs chat completion requests against the configured endpoint.
type Client struct {
	httpClient *http.Client
	endpoint   string
	model      string
	apiKey     string
	propsURL   *url.URL

	contextMu      sync.Mutex
	contextWindow  int
	contextFetched bool
}

// NewClient constructs an HTTP client with sensible defaults.
func NewClient(endpoint, model, apiKey string) (*Client, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil

	client := &http.Client{
		Timeout:   120 * time.Second,
		Transport: transport,
	}

	var propsURL *url.URL
	if parsed, err := url.Parse(endpoint); err == nil {
		propsURL = parsed.ResolveReference(&url.URL{Path: "/props"})
	}

	return &Client{
		httpClient: client,
		endpoint:   endpoint,
		model:      model,
		apiKey:     apiKey,
		propsURL:   propsURL,
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

// ChatResult wraps a plain assistant reply with optional usage metadata.
type ChatResult struct {
	Content string
	Usage   *Usage
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

type StreamTimings struct {
	PredictedPerSecond *float64
}

type StreamUpdate struct {
	Content string
	Timings *StreamTimings
	Usage   *Usage
}

type StreamHandler func(StreamUpdate) error

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
func (c *Client) Chat(ctx context.Context, systemPrompt string, history []ChatMessage) (ChatResult, error) {
	messages := buildMessages(systemPrompt, history)
	parsed, _, err := c.send(ctx, messages, defaultChatTemperature, false)
	if err != nil {
		return ChatResult{}, err
	}

	if len(parsed.Choices) == 0 {
		return ChatResult{}, fmt.Errorf("response contained no choices")
	}

	return ChatResult{
		Content: strings.TrimSpace(parsed.Choices[0].Message.Content),
		Usage:   parsed.Usage,
	}, nil
}

func (c *Client) StreamChat(ctx context.Context, systemPrompt string, history []ChatMessage, handler StreamHandler) error {
	messages := buildMessages(systemPrompt, history)
	reqBody := chatRequest{
		Model:       c.model,
		Messages:    messages,
		Temperature: defaultChatTemperature,
		Stream:      true,
		StreamOptions: &streamOptions{
			IncludeUsage: true,
		},
		ReturnProgress: true,
	}

	body, err := json.Marshal(reqBody)
	if err != nil {
		return fmt.Errorf("encode request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if c.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.apiKey)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("send request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		raw, _ := ioReadAll(resp.Body)
		lower := strings.ToLower(string(raw))
		if resp.StatusCode == http.StatusNotFound || resp.StatusCode == http.StatusBadRequest || strings.Contains(lower, "stream") {
			return ErrStreamUnsupported
		}
		return fmt.Errorf("endpoint returned %s: %s", resp.Status, raw)
	}

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 10*1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		line = strings.TrimSuffix(line, "\r")
		if line == "" || strings.HasPrefix(line, ":") {
			continue
		}
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		payload := strings.TrimPrefix(line, "data:")
		if len(payload) > 0 && payload[0] == ' ' {
			payload = payload[1:]
		}
		if strings.TrimSpace(payload) == "[DONE]" {
			return nil
		}

		var chunk streamChunk
		if err := json.Unmarshal([]byte(payload), &chunk); err != nil {
			return fmt.Errorf("decode chunk: %w", err)
		}
		var update StreamUpdate
		if len(chunk.Choices) > 0 {
			update.Content = chunk.Choices[0].Delta.Content
		}
		if chunk.Timings != nil {
			update.Timings = &StreamTimings{
				PredictedPerSecond: chunk.Timings.PredictedPerSecond,
			}
		}
		if chunk.Usage != nil {
			update.Usage = chunk.Usage
		}
		if update.Content == "" && update.Timings == nil && update.Usage == nil {
			continue
		}
		if err := handler(update); err != nil {
			return err
		}
	}

	if err := scanner.Err(); err != nil {
		return fmt.Errorf("stream read: %w", err)
	}

	return nil
}

// ContextWindow queries the backing server for its configured context window size.
func (c *Client) ContextWindow(ctx context.Context) (int, error) {
	c.contextMu.Lock()
	defer c.contextMu.Unlock()

	if c.contextFetched && c.contextWindow > 0 {
		return c.contextWindow, nil
	}

	window, err := c.fetchContextWindow(ctx)
	if err != nil {
		return 0, err
	}
	if window > 0 {
		c.contextWindow = window
		c.contextFetched = true
	}
	return window, nil
}

func (c *Client) fetchContextWindow(ctx context.Context) (int, error) {
	if c.propsURL == nil {
		return 0, fmt.Errorf("context metadata unavailable")
	}

	callCtx := ctx
	if callCtx == nil {
		callCtx = context.Background()
	}

	req, err := http.NewRequestWithContext(callCtx, http.MethodGet, c.propsURL.String(), nil)
	if err != nil {
		return 0, fmt.Errorf("create props request: %w", err)
	}
	if c.apiKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.apiKey)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return 0, fmt.Errorf("fetch props: %w", err)
	}
	defer resp.Body.Close()

	body, err := ioReadAll(resp.Body)
	if err != nil {
		return 0, fmt.Errorf("read props response: %w", err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return 0, fmt.Errorf("props request returned %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}

	var payload struct {
		DefaultGenerationSettings struct {
			NCtx   int `json:"n_ctx"`
			Params struct {
				NCtx *int `json:"n_ctx,omitempty"`
			} `json:"params"`
		} `json:"default_generation_settings"`
	}
	if err := json.Unmarshal(body, &payload); err != nil {
		return 0, fmt.Errorf("decode props payload: %w", err)
	}

	nCtx := payload.DefaultGenerationSettings.NCtx
	if nCtx <= 0 && payload.DefaultGenerationSettings.Params.NCtx != nil {
		nCtx = *payload.DefaultGenerationSettings.Params.NCtx
	}
	if nCtx <= 0 {
		return 0, fmt.Errorf("context window not reported")
	}
	return nCtx, nil
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
	Model          string         `json:"model"`
	Messages       []chatMessage  `json:"messages"`
	Temperature    float32        `json:"temperature,omitempty"`
	Stream         bool           `json:"stream,omitempty"`
	StreamOptions  *streamOptions `json:"stream_options,omitempty"`
	ReturnProgress bool           `json:"return_progress,omitempty"`
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

type streamChunk struct {
	Choices []struct {
		Delta deltaResponse `json:"delta"`
	} `json:"choices"`
	Timings *struct {
		PredictedPerSecond *float64 `json:"predicted_per_second,omitempty"`
	} `json:"timings,omitempty"`
	Usage *Usage `json:"usage,omitempty"`
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
		return chatResponse{}, nil, wrapEndpointError(c.endpoint, err)
	}
	defer resp.Body.Close()

	if stream {
		return chatResponse{}, nil, fmt.Errorf("streaming mode not supported in this path")
	}

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

type streamOptions struct {
	IncludeUsage bool `json:"include_usage,omitempty"`
}

// EndpointUnreachableError signals that the configured endpoint rejected the
// TCP connection.
type EndpointUnreachableError struct {
	Endpoint string
	Err      error
}

func (e *EndpointUnreachableError) Error() string {
	if e.Err != nil {
		return fmt.Sprintf("endpoint %s unreachable: %v", e.Endpoint, e.Err)
	}
	return fmt.Sprintf("endpoint %s unreachable", e.Endpoint)
}

func (e *EndpointUnreachableError) Unwrap() error {
	return e.Err
}

func (e *EndpointUnreachableError) Is(target error) bool {
	return target == ErrEndpointUnreachable
}

func wrapEndpointError(endpoint string, err error) error {
	if err == nil {
		return nil
	}
	if isConnectionRefused(err) {
		return &EndpointUnreachableError{
			Endpoint: endpoint,
			Err:      err,
		}
	}
	return fmt.Errorf("send request: %w", err)
}

func isConnectionRefused(err error) bool {
	if err == nil {
		return false
	}
	var urlErr *url.Error
	if errors.As(err, &urlErr) {
		err = urlErr.Err
	}
	var opErr *net.OpError
	if errors.As(err, &opErr) {
		if errors.Is(opErr.Err, syscall.ECONNREFUSED) || errors.Is(opErr.Err, syscall.EHOSTUNREACH) || errors.Is(opErr.Err, syscall.ENETUNREACH) {
			return true
		}
	}
	return false
}
