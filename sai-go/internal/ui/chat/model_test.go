package chat

import (
	tea "github.com/charmbracelet/bubbletea"
	"testing"
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
