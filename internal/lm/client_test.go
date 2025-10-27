package lm

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestParseStructuredDirect(t *testing.T) {
	answer, err := parseStructured(`{"explanation":"Do it","recommended_command":"echo hi"}`)
	if err != nil {
		t.Fatalf("parseStructured returned error: %v", err)
	}
	if answer.Explanation != "Do it" || answer.RecommendedCommand != "echo hi" {
		t.Fatalf("unexpected structured answer: %+v", answer)
	}
}

func TestParseStructuredFallback(t *testing.T) {
	payload := `
Sure, here's what you asked for:
{
  "explanation": "Use ls to list hidden files.",
  "recommended_command": "ls -a"
}
`
	answer, err := parseStructured(payload)
	if err != nil {
		t.Fatalf("parseStructured fallback error: %v", err)
	}
	if answer.RecommendedCommand != "ls -a" {
		t.Fatalf("expected recommended_command to be ls -a, got %q", answer.RecommendedCommand)
	}
}

func TestParseStructuredError(t *testing.T) {
	if _, err := parseStructured("not json"); err == nil {
		t.Fatal("expected error for invalid structured payload")
	}
}

func TestStreamChatDeliversChunks(t *testing.T) {
	type payload struct {
		Stream         bool `json:"stream"`
		ReturnProgress bool `json:"return_progress"`
		StreamOptions  struct {
			IncludeUsage bool `json:"include_usage"`
		} `json:"stream_options"`
	}

	var request payload
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("failed to read request body: %v", err)
		}
		if err := json.Unmarshal(body, &request); err != nil {
			t.Fatalf("failed to decode request body: %v", err)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		flusher, _ := w.(http.Flusher)
		io.WriteString(w, "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n")
		if flusher != nil {
			flusher.Flush()
		}
		io.WriteString(w, "data: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n")
		if flusher != nil {
			flusher.Flush()
		}
		io.WriteString(w, "data: [DONE]\n\n")
	}))
	defer server.Close()

	client, err := NewClient(server.URL, "model", "")
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	var chunks []string
	handler := func(update StreamUpdate) error {
		chunks = append(chunks, update.Content)
		return nil
	}

	err = client.StreamChat(context.Background(), "system", []ChatMessage{
		{Role: "user", Content: "hi"},
	}, handler)
	if err != nil {
		t.Fatalf("StreamChat returned error: %v", err)
	}

	if !request.Stream {
		t.Fatalf("expected stream flag to be true in request payload")
	}
	if !request.StreamOptions.IncludeUsage {
		t.Fatalf("expected include_usage to be true in stream options")
	}
	if !request.ReturnProgress {
		t.Fatalf("expected return_progress to be true in request payload")
	}

	want := []string{"hello", " world"}
	if len(chunks) != len(want) {
		t.Fatalf("expected %d chunks, got %d", len(want), len(chunks))
	}
	for i := range want {
		if chunks[i] != want[i] {
			t.Fatalf("chunk %d mismatch: want %q got %q", i, want[i], chunks[i])
		}
	}
}

func TestStreamChatUnsupported(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name   string
		status int
		body   string
	}{
		{name: "not found", status: http.StatusNotFound, body: "missing"},
		{name: "bad request", status: http.StatusBadRequest, body: "stream parameter disabled"},
		{name: "body mentions stream", status: http.StatusInternalServerError, body: "streaming not available"},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(tc.status)
				io.WriteString(w, tc.body)
			}))
			defer server.Close()

			client, err := NewClient(server.URL, "model", "")
			if err != nil {
				t.Fatalf("NewClient returned error: %v", err)
			}

			err = client.StreamChat(context.Background(), "system", nil, func(StreamUpdate) error { return nil })
			if !errors.Is(err, ErrStreamUnsupported) {
				t.Fatalf("expected ErrStreamUnsupported, got %v", err)
			}
		})
	}
}

func TestStreamChatPropagatesHandlerError(t *testing.T) {
	stop := errors.New("stop")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\n")
	}))
	defer server.Close()

	client, err := NewClient(server.URL, "model", "")
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	err = client.StreamChat(context.Background(), "system", nil, func(update StreamUpdate) error {
		if strings.TrimSpace(update.Content) != "" {
			return stop
		}
		return nil
	})
	if !errors.Is(err, stop) {
		t.Fatalf("expected handler error to propagate, got %v", err)
	}
}

func TestStreamChatEmitsTimings(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}],\"timings\":{\"predicted_per_second\":12.5}}\n\n")
		io.WriteString(w, "data: [DONE]\n\n")
	}))
	defer server.Close()

	client, err := NewClient(server.URL, "model", "")
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	var gotTimings []*StreamTimings
	err = client.StreamChat(context.Background(), "system", nil, func(update StreamUpdate) error {
		if update.Timings != nil {
			gotTimings = append(gotTimings, update.Timings)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("StreamChat returned error: %v", err)
	}
	if len(gotTimings) != 1 {
		t.Fatalf("expected 1 timing entry, got %d", len(gotTimings))
	}
	if gotTimings[0].PredictedPerSecond == nil || *gotTimings[0].PredictedPerSecond != 12.5 {
		t.Fatalf("unexpected predicted rate: %+v", gotTimings[0])
	}
}

func TestStreamChatReportsUsage(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer r.Body.Close()
		w.Header().Set("Content-Type", "text/event-stream")
		io.WriteString(w, "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":3,\"total_tokens\":15}}\n\n")
		io.WriteString(w, "data: [DONE]\n\n")
	}))
	defer server.Close()

	client, err := NewClient(server.URL, "model", "")
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	var usages []*Usage
	err = client.StreamChat(context.Background(), "system", nil, func(update StreamUpdate) error {
		if update.Usage != nil {
			usages = append(usages, update.Usage)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("StreamChat returned error: %v", err)
	}
	if len(usages) != 1 {
		t.Fatalf("expected usage metadata, got %d entries", len(usages))
	}
	if usages[0].TotalTokens == nil || *usages[0].TotalTokens != 15 {
		t.Fatalf("unexpected total tokens: %+v", usages[0])
	}
}

func TestContextWindowFetch(t *testing.T) {
	propsBody := `{
		"default_generation_settings": {
			"id": 0,
			"n_ctx": 4096,
			"params": {
				"n_ctx": 4096
			}
		}
	}`

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/props"):
			io.WriteString(w, propsBody)
		default:
			w.WriteHeader(http.StatusOK)
			io.WriteString(w, "{}")
		}
	}))
	defer server.Close()

	client, err := NewClient(server.URL+"/v1/chat/completions", "model", "")
	if err != nil {
		t.Fatalf("NewClient returned error: %v", err)
	}

	got, err := client.ContextWindow(context.Background())
	if err != nil {
		t.Fatalf("ContextWindow returned error: %v", err)
	}
	if got != 4096 {
		t.Fatalf("expected context window 4096, got %d", got)
	}
}
