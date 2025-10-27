package ui

import (
	"testing"

	"github.com/slomin/sai/internal/lm"
)

func TestPreviewText(t *testing.T) {
	src := "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vestibulum ut eros."
	got := previewText(src)
	runes := []rune(got)
	if len(runes) > 73 {
		t.Fatalf("previewText exceeded expected length: %q", got)
	}
	if runes[len(runes)-1] != '\u2026' {
		t.Fatalf("previewText should end with ellipsis: %q", got)
	}
}

func TestPreviewTextEmpty(t *testing.T) {
	if got := previewText("   "); got != "(empty)" {
		t.Fatalf("previewText expected (empty), got %q", got)
	}
}

func TestFormatUsage(t *testing.T) {
	prompt := 42
	completion := 13
	usage := &lm.Usage{
		PromptTokens:     &prompt,
		CompletionTokens: &completion,
	}
	got := formatUsage(usage)
	want := "prompt 42 · completion 13 tokens"
	if got != want {
		t.Fatalf("formatUsage mismatch:\n  got:  %q\n  want: %q", got, want)
	}

	if got := formatUsage(nil); got != "" {
		t.Fatalf("formatUsage expected empty string for nil usage, got %q", got)
	}
}

func TestMenuStateInitialSelection(t *testing.T) {
	state := newMenuState(lm.StructuredAnswer{
		Explanation:        "Explain",
		RecommendedCommand: "",
	})

	if state.selected != 0 {
		t.Fatalf("expected first option to be selected, got %d", state.selected)
	}

	state.next()
	if state.entries[state.selected].kind != menuCancel {
		t.Fatalf("expected cancel option after cycling, got %v", state.entries[state.selected].kind)
	}

	state.previous()
	if state.entries[state.selected].kind != menuExplanation {
		t.Fatalf("expected to cycle back to explanation, got %v", state.entries[state.selected].kind)
	}
}

func TestTrimTrailingWord(t *testing.T) {
	if got := trimTrailingWord("hello world   "); got != "hello " {
		t.Fatalf("trimTrailingWord mismatch: %q", got)
	}
	if got := trimTrailingWord("   "); got != "" {
		t.Fatalf("trimTrailingWord for spaces expected empty, got %q", got)
	}
}

func TestTrimLastRune(t *testing.T) {
	if got := trimLastRune("hello"); got != "hell" {
		t.Fatalf("trimLastRune mismatch: %q", got)
	}
	if got := trimLastRune(""); got != "" {
		t.Fatalf("trimLastRune empty expected empty, got %q", got)
	}
}
