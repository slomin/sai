package lm

import "testing"

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
