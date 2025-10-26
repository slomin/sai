package chat

import (
	"context"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/slomin/sai/internal/lm"
)

func TestHandleAutoStartAppendsPrompt(t *testing.T) {
	initial := "inspect repo"
	m := newModel(Options{SystemPrompt: "system", AutoPrompt: initial})
	if m.autoPrompt == "" {
		t.Fatalf("expected auto prompt to be set")
	}

	updated, cmd := m.handleAutoStart()
	typed, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model type, got %T", updated)
	}
	m = typed

	if m.autoPrompt != "" {
		t.Fatalf("auto prompt should be cleared")
	}
	if !m.sending {
		t.Fatalf("model should be sending after auto start")
	}
	if len(m.history) != 1 {
		t.Fatalf("expected one history entry, got %d", len(m.history))
	}
	if got := m.history[0].Content; got != initial {
		t.Fatalf("history content mismatch: %s", got)
	}
	if cmd == nil {
		t.Fatalf("expected command to be scheduled")
	}
}

func TestInitSchedulesAutoStart(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system", AutoPrompt: "hello"})
	cmd := m.Init()
	if cmd == nil {
		t.Fatalf("expected init command when auto prompt present")
	}
	msg := cmd()
	found := false
	switch v := msg.(type) {
	case autoStartMsg:
		found = true
	case tea.BatchMsg:
		for _, sub := range v {
			if sub == nil {
				continue
			}
			if _, ok := sub().(autoStartMsg); ok {
				found = true
				break
			}
		}
	}
	if !found {
		t.Fatalf("expected autoStartMsg, got %T", msg)
	}
}

func TestHandleStreamEventAppendsChunks(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system", Stream: true})
	m.history = append(m.history, lm.ChatMessage{Role: "user", Content: "hello"})
	m.streamCh = make(chan streamEvent)

	updated, cmd := m.handleStreamEvent(streamEvent{chunk: "hi"})
	if cmd == nil {
		t.Fatalf("expected command to continue listening")
	}

	typed, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model type, got %T", updated)
	}
	if len(typed.history) != 2 {
		t.Fatalf("expected two history entries, got %d", len(typed.history))
	}
	last := typed.history[len(typed.history)-1]
	if last.Role != "assistant" || last.Content != "hi" {
		t.Fatalf("unexpected assistant entry: %+v", last)
	}
}

func TestHandleStreamEventFallbackDisablesStreaming(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system", Stream: true})
	m.sending = true
	m.streamEnabled = true
	m.pendingRequest = []lm.ChatMessage{{Role: "user", Content: "hi"}}
	m.history = append(m.history, lm.ChatMessage{Role: "assistant", Content: ""})
	m.streamCh = make(chan streamEvent)
	m.streamCancel = func() {}

	updated, cmd := m.handleStreamEvent(streamEvent{err: lm.ErrStreamUnsupported})
	if cmd == nil {
		t.Fatalf("expected fallback command to be scheduled")
	}

	typed, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model type, got %T", updated)
	}
	if typed.streamEnabled {
		t.Fatalf("expected streaming to be disabled")
	}
	if typed.pendingRequest != nil {
		t.Fatalf("pending request should be cleared")
	}
	if len(typed.history) != 0 {
		t.Fatalf("assistant placeholder should be dropped, history: %+v", typed.history)
	}
	if typed.err != nil {
		t.Fatalf("expected no error, got %v", typed.err)
	}
	if !typed.sending {
		t.Fatalf("expected sending to remain true for fallback request")
	}
}

func TestStreamingLifecycleAllowsMultipleMessages(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system", Stream: true})
	count := 0
	m.streamLauncher = func(ctx context.Context, client *lm.Client, system string, history []lm.ChatMessage) (chan streamEvent, context.CancelFunc) {
		ch := make(chan streamEvent, 4)
		streamCtx, cancel := context.WithCancel(context.Background())
		turn := count
		go func() {
			defer close(ch)
			defer cancel()
			var chunk string
			if turn == 0 {
				chunk = "first"
			} else {
				chunk = "second"
			}
			select {
			case <-streamCtx.Done():
				return
			case ch <- streamEvent{chunk: chunk}:
			}
			select {
			case <-streamCtx.Done():
			case ch <- streamEvent{done: true}:
			}
		}()
		count++
		return ch, cancel
	}

	m.history = append(m.history, lm.ChatMessage{Role: "user", Content: "hello"})
	m.sending = true
	cmd := m.startStreaming(append([]lm.ChatMessage(nil), m.history...))
	m = drainCommands(t, m, cmd)

	if m.sending {
		t.Fatalf("expected sending to be false after stream completion")
	}
	if m.streamCh != nil {
		t.Fatalf("stream channel should be nil after stream completion")
	}
	if got := m.history[len(m.history)-1].Content; got != "first" {
		t.Fatalf("expected first assistant reply, got %q", got)
	}

	m.input.SetValue("second message")
	updated, cmd := m.handleSubmit()
	typed, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model type, got %T", updated)
	}
	m = typed
	if !m.sending {
		t.Fatalf("expected sending to be true while streaming second message")
	}
	if cmd == nil {
		t.Fatalf("expected command for second stream")
	}

	m = drainCommands(t, m, cmd)
	if m.sending {
		t.Fatalf("expected sending to be false after second stream")
	}
	if got := m.history[len(m.history)-1].Content; got != "second" {
		t.Fatalf("expected second assistant reply, got %q", got)
	}
}

func drainCommands(t *testing.T, m model, cmd tea.Cmd) model {
	t.Helper()
	current := m
	for cmd != nil {
		msg := cmd()
		if msg == nil {
			break
		}
		updated, next := current.Update(msg)
		typed, ok := updated.(model)
		if !ok {
			t.Fatalf("expected model type, got %T", updated)
		}
		current = typed
		cmd = next
	}
	return current
}

func TestAddAssistantPlaceholderAppendsNewEntry(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system"})
	m.history = append(m.history, lm.ChatMessage{Role: "assistant", Content: "old"})

	m.addAssistantPlaceholder()

	if len(m.history) != 2 {
		t.Fatalf("expected second assistant entry")
	}
	last := m.history[len(m.history)-1]
	if last.Role != "assistant" || last.Content != "" {
		t.Fatalf("expected blank assistant entry, got %+v", last)
	}
}

func TestAppendStreamChunkPreservesNewlines(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system", Stream: true})
	m.history = append(m.history, lm.ChatMessage{Role: "user", Content: "hello"})
	m.addAssistantPlaceholder()

	m.appendStreamChunk("First line")
	m.appendStreamChunk("\n")
	m.appendStreamChunk("Second line")

	last := m.history[len(m.history)-1]
	if last.Content != "First line\nSecond line" {
		t.Fatalf("expected newline between lines, got %q", last.Content)
	}
}

func TestAppendStreamChunkAppendsVerbatim(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system", Stream: true})
	m.history = append(m.history, lm.ChatMessage{Role: "user", Content: "hello"})
	m.addAssistantPlaceholder()

	m.appendStreamChunk("print('hi')\n")
	m.appendStreamChunk("    return 42\n")

	last := m.history[len(m.history)-1]
	if last.Content != "print('hi')\n    return 42\n" {
		t.Fatalf("expected chunk content to be appended verbatim, got %q", last.Content)
	}
}

func TestHandleStreamEventDoesNotForceScrollWhenNotAtBottom(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system", Stream: true})
	m.history = append(m.history,
		lm.ChatMessage{Role: "user", Content: "hello"},
		lm.ChatMessage{Role: "assistant", Content: "Line 1\nLine 2\nLine 3"},
	)
	m.viewport.Width = 20
	m.viewport.Height = 1
	m.refreshViewport()
	m.viewport.SetYOffset(0)
	m.tail = false
	if m.viewport.AtBottom() {
		t.Fatalf("expected viewport to not be at bottom")
	}

	m.streamCh = make(chan streamEvent)
	updated, cmd := m.handleStreamEvent(streamEvent{chunk: " more"})
	if cmd == nil {
		t.Fatalf("expected command to continue listening")
	}
	typed, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model type, got %T", updated)
	}
	if typed.viewport.YOffset != 0 {
		t.Fatalf("expected viewport Y offset to remain 0, got %d", typed.viewport.YOffset)
	}
}

func TestHandleStreamEventAutoClosesFence(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system", Stream: true})
	m.history = append(m.history, lm.ChatMessage{Role: "user", Content: "hello"})
	m.streamCh = make(chan streamEvent)
	m.streamCancel = func() {}
	m.sending = true

	m.appendStreamChunk("```sh\nls\n")
	updated, _ := m.handleStreamEvent(streamEvent{done: true})
	typed, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model type, got %T", updated)
	}
	last := typed.history[len(typed.history)-1].Content
	if strings.Count(last, "```")%2 != 0 {
		t.Fatalf("expected code fence to be closed, got %q", last)
	}
	if !strings.HasSuffix(last, "```") {
		t.Fatalf("expected closing fence at end, got %q", last)
	}
}

func TestTriggerCopyLastAssistantWithoutReplySetsStatus(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system", Stream: true})
	cmd := m.triggerCopyLastAssistant()
	if cmd == nil {
		t.Fatalf("expected command when no assistant reply available")
	}
	if got := m.statusMessage; got == "" {
		t.Fatalf("expected status message to explain copy failure")
	}
}

func TestTriggerCopyLastAssistantSkipsEmptyReplies(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system"})
	m.history = append(m.history,
		lm.ChatMessage{Role: "assistant", Content: "   "},
		lm.ChatMessage{Role: "assistant", Content: "full message"},
	)

	cmd := m.triggerCopyLastAssistant()
	if cmd == nil {
		t.Fatalf("expected copy command when assistant reply present")
	}
}

func TestQuitMsgStopsStreaming(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system", Stream: true})
	cancelled := false
	m.streamCh = make(chan streamEvent)
	m.streamCancel = func() {
		cancelled = true
	}

	updated, _ := m.Update(tea.QuitMsg{})
	typed, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model type, got %T", updated)
	}
	if !cancelled {
		t.Fatalf("expected cancel function to run")
	}
	if typed.streamCh != nil {
		t.Fatalf("expected stream channel to be cleared")
	}
}
