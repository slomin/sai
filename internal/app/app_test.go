package app

import "testing"

func TestSelectChatLaunchGuessMode(t *testing.T) {
	cfg := Config{GuessMode: true, SystemPrompt: "custom"}
	launch, ok := selectChatLaunch(cfg, "anything")
	if !ok {
		t.Fatalf("expected launch for guess mode")
	}
	if launch.SystemPrompt != resolveIntentPrompt(cfg.SystemPrompt) {
		t.Fatalf("intent prompt mismatch")
	}
	if launch.AutoPrompt != defaultIntentPrompt {
		t.Fatalf("auto prompt should be default intent")
	}
	if launch.Title != "SAI Intent Chat" {
		t.Fatalf("title mismatch: %s", launch.Title)
	}
}

func TestSelectChatLaunchEmptyPrompt(t *testing.T) {
	cfg := Config{}
	launch, ok := selectChatLaunch(cfg, "")
	if !ok {
		t.Fatalf("expected launch for empty prompt")
	}
	if launch.SystemPrompt != resolveChatPrompt(cfg.SystemPrompt) {
		t.Fatalf("chat prompt mismatch")
	}
	if launch.AutoPrompt != "" {
		t.Fatalf("auto prompt should be empty")
	}
	if launch.Title != "SAI Chat" {
		t.Fatalf("title mismatch: %s", launch.Title)
	}
}

func TestSelectChatLaunchStructured(t *testing.T) {
	cfg := Config{}
	if _, ok := selectChatLaunch(cfg, "ls -la"); ok {
		t.Fatalf("unexpected launch for non-empty prompt")
	}
}
