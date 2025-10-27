package chat

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

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

func TestHandleSubmitWithoutContext(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system", Stream: true, IncludeContext: boolPtr(false)})
	m.streamLauncher = func(ctx context.Context, client *lm.Client, system string, history []lm.ChatMessage) (chan streamEvent, context.CancelFunc) {
		if len(history) != 1 {
			t.Fatalf("expected single message, got %d", len(history))
		}
		if strings.Contains(history[0].Content, "Context:") {
			t.Fatalf("expected prompt without context, got %q", history[0].Content)
		}
		if history[0].Content != "hello there" {
			t.Fatalf("expected raw prompt, got %q", history[0].Content)
		}
		ch := make(chan streamEvent)
		return ch, func() {}
	}

	m.input.SetValue("hello there")
	if _, cmd := m.handleSubmit(); cmd == nil {
		t.Fatalf("expected streaming command")
	}
}

func TestHandleAutoStartWithoutContext(t *testing.T) {
	m := newModel(Options{
		SystemPrompt:   "system",
		Stream:         true,
		AutoPrompt:     "status report",
		IncludeContext: boolPtr(false),
	})
	m.streamLauncher = func(ctx context.Context, client *lm.Client, system string, history []lm.ChatMessage) (chan streamEvent, context.CancelFunc) {
		if len(history) != 1 {
			t.Fatalf("expected single message, got %d", len(history))
		}
		if strings.Contains(history[0].Content, "Context:") {
			t.Fatalf("expected prompt without context, got %q", history[0].Content)
		}
		if history[0].Content != "status report" {
			t.Fatalf("expected raw auto prompt, got %q", history[0].Content)
		}
		ch := make(chan streamEvent)
		return ch, func() {}
	}

	if _, cmd := m.handleAutoStart(); cmd == nil {
		t.Fatalf("expected streaming command")
	}
}

func TestHandleAutoStartInternalDoesNotShowUserMessage(t *testing.T) {
	m := newModel(Options{
		SystemPrompt:       "system",
		Stream:             true,
		AutoPrompt:         "give me an intro",
		AutoPromptInternal: true,
	})

	var sentHistory []lm.ChatMessage
	m.streamLauncher = func(ctx context.Context, client *lm.Client, system string, history []lm.ChatMessage) (chan streamEvent, context.CancelFunc) {
		sentHistory = append([]lm.ChatMessage(nil), history...)
		ch := make(chan streamEvent)
		return ch, func() {}
	}

	updated, cmd := m.handleAutoStart()
	typed, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model type, got %T", updated)
	}
	if cmd == nil {
		t.Fatalf("expected streaming command")
	}
	for _, entry := range typed.history {
		if entry.Role == "user" {
			t.Fatalf("internal auto prompt should not append user message, history: %+v", typed.history)
		}
	}
	if len(sentHistory) == 0 {
		t.Fatalf("expected synthesized user message in sent history")
	}
	last := sentHistory[len(sentHistory)-1]
	if last.Role != "user" || strings.TrimSpace(last.Content) == "" {
		t.Fatalf("unexpected sent history entry: %+v", last)
	}
}

func TestContextSummaryTracksUsage(t *testing.T) {
	limit := 4096
	m := newModel(Options{SystemPrompt: "system", DisplayContext: true, ContextWindow: &limit})

	initial := m.contextSummary()
	if !strings.Contains(initial, "0/4096") {
		t.Fatalf("expected initial context summary to mention 0/4096, got %q", initial)
	}

	m.applyUsage(&lm.Usage{TotalTokens: intPtr(1024)})
	updated := m.contextSummary()
	if !strings.Contains(updated, "1024/4096") {
		t.Fatalf("expected updated summary to mention 1024/4096, got %q", updated)
	}
}

func TestHandleStreamEventUsageUpdatesContext(t *testing.T) {
	limit := 2048
	m := newModel(Options{SystemPrompt: "system", Stream: true, DisplayContext: true, ContextWindow: &limit})

	updated, _ := m.handleStreamEvent(streamEvent{usage: &lm.Usage{TotalTokens: intPtr(512)}})
	typed, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model type, got %T", updated)
	}
	if typed.contextUsed != 512 {
		t.Fatalf("expected contextUsed to be 512, got %d", typed.contextUsed)
	}
}

func boolPtr(v bool) *bool {
	return &v
}

func intPtr(v int) *int {
	return &v
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

func TestTabSelectsSnippet(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system"})
	m.history = append(m.history,
		lm.ChatMessage{Role: "assistant", Content: "Here's code:\n```sh\necho hi\n```\n"},
	)

	updated, cmd := m.Update(tea.KeyMsg{Type: tea.KeyTab})
	if cmd != nil {
		t.Fatalf("expected no command on tab, got %#v", cmd)
	}
	typed, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model type, got %T", updated)
	}
	if typed.snippet == nil {
		t.Fatalf("expected snippet selection to be active")
	}
	if typed.snippet.Language != "sh" {
		t.Fatalf("expected language sh, got %q", typed.snippet.Language)
	}
	if typed.snippet.Code != "echo hi" {
		t.Fatalf("unexpected snippet code: %q", typed.snippet.Code)
	}
	if typed.snippet.BlockIndex != 0 {
		t.Fatalf("expected block index 0, got %d", typed.snippet.BlockIndex)
	}
	if raw, ok := SelectedSnippet(typed); !ok || raw != "echo hi" {
		t.Fatalf("selected snippet mismatch: %q ok=%v", raw, ok)
	}
}

func TestTabCyclesThroughSnippets(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system"})
	m.history = append(m.history,
		lm.ChatMessage{Role: "assistant", Content: "```python\nprint('first')\n```\n```sh\necho second\n```"},
		lm.ChatMessage{Role: "assistant", Content: "```bash\nls -la\n```"},
	)

	// First tab selects latest message's block
	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyTab})
	first, ok := updated.(model)
	if !ok || first.snippet == nil {
		t.Fatalf("expected first snippet selection")
	}
	if first.snippet.Code != "ls -la" {
		t.Fatalf("expected newest snippet, got %q", first.snippet.Code)
	}
	if first.snippet.BlockIndex != 0 || first.snippet.MessageIndex != 1 {
		t.Fatalf("unexpected indices: msg %d block %d", first.snippet.MessageIndex, first.snippet.BlockIndex)
	}

	// Second tab moves to previous block (same message earlier block)
	secondModel, _ := first.Update(tea.KeyMsg{Type: tea.KeyTab})
	second, ok := secondModel.(model)
	if !ok || second.snippet == nil {
		t.Fatalf("expected second snippet selection")
	}
	if second.snippet.Code != "echo second" {
		t.Fatalf("expected second snippet, got %q", second.snippet.Code)
	}
	if second.snippet.BlockIndex != 1 || second.snippet.MessageIndex != 0 {
		t.Fatalf("unexpected indices for second snippet: msg %d block %d", second.snippet.MessageIndex, second.snippet.BlockIndex)
	}

	// Third tab moves to earliest block
	thirdModel, _ := second.Update(tea.KeyMsg{Type: tea.KeyTab})
	third, ok := thirdModel.(model)
	if !ok || third.snippet == nil {
		t.Fatalf("expected third snippet selection")
	}
	if third.snippet.Code != "print('first')" {
		t.Fatalf("expected first snippet, got %q", third.snippet.Code)
	}
	if third.snippet.BlockIndex != 0 || third.snippet.MessageIndex != 0 {
		t.Fatalf("unexpected indices for third snippet: msg %d block %d", third.snippet.MessageIndex, third.snippet.BlockIndex)
	}

	// Fourth tab should report no more snippets
	fourthModel, _ := third.Update(tea.KeyMsg{Type: tea.KeyTab})
	fourth, ok := fourthModel.(model)
	if !ok {
		t.Fatalf("expected model type after fourth tab")
	}
	if fourth.snippet != nil {
		t.Fatalf("expected snippet to be nil after cycling all")
	}
	if fourth.statusMessage != "No more snippets" {
		t.Fatalf("expected status message about completion, got %q", fourth.statusMessage)
	}
}

func TestHandleStreamEventComputesStreamRate(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system", Stream: true})
	m.streamCh = make(chan streamEvent)

	updated, _ := m.handleStreamEvent(streamEvent{chunk: "Hello"})
	typed, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model, got %T", updated)
	}
	if typed.streamTokens != 1 {
		t.Fatalf("expected 1 token, got %d", typed.streamTokens)
	}
	if typed.streamStarted.IsZero() {
		t.Fatalf("expected stream start to be recorded")
	}

	time.Sleep(10 * time.Millisecond)

	updated, _ = typed.handleStreamEvent(streamEvent{chunk: " world"})
	typed, ok = updated.(model)
	if !ok {
		t.Fatalf("expected model, got %T", updated)
	}
	if typed.streamTokens != 2 {
		t.Fatalf("expected 2 tokens, got %d", typed.streamTokens)
	}
	if typed.streamRate <= 0 {
		t.Fatalf("expected positive stream rate, got %f", typed.streamRate)
	}
}

func TestHandleStreamEventPrefersPredictedRate(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system", Stream: true})
	m.streamCh = make(chan streamEvent)

	rate := 37.5
	updated, _ := m.handleStreamEvent(streamEvent{
		chunk:         "Hello",
		predictedRate: &rate,
	})
	typed, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model, got %T", updated)
	}
	if typed.streamRate != rate {
		t.Fatalf("expected stream rate %f, got %f", rate, typed.streamRate)
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

func TestClipboardFallbackDisplaysSnippetInline(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system"})
	m.history = append(m.history,
		lm.ChatMessage{Role: "assistant", Content: "```sh\necho hi\n```"},
	)
	m.viewport.Width = 80
	m.viewport.Height = 20
	if !m.selectLatestSnippet() {
		t.Fatalf("expected snippet selection to succeed")
	}

	updated, cmd := m.Update(snippetCopiedMsg{err: errors.New("clipboard unavailable")})
	if cmd != nil {
		t.Fatalf("expected no command on clipboard failure, got %#v", cmd)
	}
	typed, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model, got %T", updated)
	}
	if typed.fallbackSnippet == nil {
		t.Fatalf("expected fallback snippet to be set")
	}
	view := typed.View()
	if !strings.Contains(view, "Clipboard unavailable – snippet shown below") {
		t.Fatalf("expected fallback notice in view, got %q", view)
	}
}

func TestFooterHintsToggleTabShortcut(t *testing.T) {
	m := newModel(Options{SystemPrompt: "system"})
	view := m.View()
	if strings.Contains(view, "Tab select snippet") {
		t.Fatalf("tab shortcut should be hidden when no snippets exist: %q", view)
	}

	m.history = append(m.history,
		lm.ChatMessage{Role: "assistant", Content: "```python\nprint('hi')\n```"},
	)
	m.refreshViewport()
	view = m.View()
	if !strings.Contains(view, "Tab select snippet") {
		t.Fatalf("tab shortcut should appear when snippets exist: %q", view)
	}
}

func TestEnsureRendererRespectsEnvironmentStyle(t *testing.T) {
	original := os.Getenv("GLAMOUR_STYLE")
	defer os.Setenv("GLAMOUR_STYLE", original)

	os.Setenv("GLAMOUR_STYLE", "dark")
	darkModel := newModel(Options{SystemPrompt: "system"})
	darkModel.viewport.Width = 80
	darkRender := darkModel.renderAssistant(0, "```go\nfmt.Println(\"hi\")\n```")

	os.Setenv("GLAMOUR_STYLE", "light")
	lightModel := newModel(Options{SystemPrompt: "system"})
	lightModel.viewport.Width = 80
	lightRender := lightModel.renderAssistant(0, "```go\nfmt.Println(\"hi\")\n```")

	if darkRender == lightRender {
		t.Fatalf("expected different render output for dark vs light styles")
	}
}

func TestSnippetSelectionHighlightsInView(t *testing.T) {
	const highlightToken = "▶ Snippet selected"

	m := newModel(Options{SystemPrompt: "system"})
	m.history = append(m.history,
		lm.ChatMessage{Role: "assistant", Content: "Here:\n```go\nfmt.Println(\"hi\")\n```"},
	)
	m.viewport.Width = 80
	m.viewport.Height = 20
	m.refreshViewport()
	baseView := m.View()
	if strings.Count(baseView, "Snippet selected") != 0 {
		t.Fatalf("highlight text should not appear before snippet selection")
	}

	if !m.selectLatestSnippet() {
		t.Fatalf("expected snippet selection")
	}
	m.refreshViewport()
	view := m.View()
	if strings.Count(view, "Snippet selected") < 2 {
		t.Fatalf("expected highlighted snippet text to appear twice in view, got %q", view)
	}
}
