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
	if !launch.IncludeContext {
		t.Fatalf("intent chat should include context")
	}
	if launch.ShowContext {
		t.Fatalf("intent chat should not show context meter")
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
	if !launch.IncludeContext {
		t.Fatalf("default chat should include context")
	}
	if launch.ShowContext {
		t.Fatalf("default chat should not show context meter")
	}
}

func TestSelectChatLaunchStructured(t *testing.T) {
	cfg := Config{}
	if _, ok := selectChatLaunch(cfg, "ls -la"); ok {
		t.Fatalf("unexpected launch for non-empty prompt")
	}
}

func TestSelectChatLaunchLongChat(t *testing.T) {
	cfg := Config{LongChat: true}
	launch, ok := selectChatLaunch(cfg, "")
	if !ok {
		t.Fatalf("expected launch for long chat")
	}
	if launch.SystemPrompt != resolveLongChatPrompt(cfg.SystemPrompt) {
		t.Fatalf("long chat prompt mismatch")
	}
	if launch.AutoPrompt != "" {
		t.Fatalf("auto prompt should be empty for long chat")
	}
	if launch.Title != "SAI Long Chat" {
		t.Fatalf("title mismatch: %s", launch.Title)
	}
	if launch.IncludeContext {
		t.Fatalf("long chat should disable context")
	}
	if !launch.ShowContext {
		t.Fatalf("long chat should surface context meter")
	}
}

func TestSelectChatLaunchInteractiveHelp(t *testing.T) {
	cfg := Config{InteractiveHelp: true}
	launch, ok := selectChatLaunch(cfg, "")
	if !ok {
		t.Fatalf("expected launch for interactive help")
	}
	if launch.SystemPrompt != resolveInteractiveHelpPrompt(cfg.SystemPrompt) {
		t.Fatalf("interactive help prompt mismatch")
	}
	if launch.Title != "SAI Help Desk" {
		t.Fatalf("interactive help title mismatch: %s", launch.Title)
	}
	if launch.IncludeContext {
		t.Fatalf("interactive help should ignore workspace context")
	}
	if launch.ShowContext {
		t.Fatalf("interactive help should not show context meter")
	}
}

func TestResolveEndpointAndModelDefaultsRemote(t *testing.T) {
	cfg := Config{}
	updated := resolveEndpointAndModel(cfg)
	if updated.Endpoint != remoteEndpoint {
		t.Fatalf("expected remote endpoint default, got %s", updated.Endpoint)
	}
	if updated.Model != remoteModel {
		t.Fatalf("expected remote model default, got %s", updated.Model)
	}
}

func TestResolveEndpointAndModelPreserveRemoteOverrides(t *testing.T) {
	cfg := Config{
		Endpoint:         "https://api.example.com/v1/chat/completions",
		Model:            "models/custom",
		EndpointProvided: true,
		ModelProvided:    true,
	}
	updated := resolveEndpointAndModel(cfg)
	if updated.Endpoint != cfg.Endpoint {
		t.Fatalf("expected endpoint override to be preserved")
	}
	if updated.Model != cfg.Model {
		t.Fatalf("expected model override to be preserved")
	}
}

func TestResolveEndpointAndModelDefaultsLocal(t *testing.T) {
	cfg := Config{
		LocalPreset: true,
		Endpoint:    remoteEndpoint,
		Model:       remoteModel,
	}
	updated := resolveEndpointAndModel(cfg)
	if updated.Endpoint != localEndpoint {
		t.Fatalf("expected local endpoint default, got %s", updated.Endpoint)
	}
	if updated.Model != localModel {
		t.Fatalf("expected local model default, got %s", updated.Model)
	}
}

func TestResolveEndpointAndModelPreserveLocalOverrides(t *testing.T) {
	cfg := Config{
		LocalPreset:      true,
		Endpoint:         "http://localhost:8080/v1/chat/completions",
		Model:            "models/another-local",
		EndpointProvided: true,
		ModelProvided:    true,
	}
	updated := resolveEndpointAndModel(cfg)
	if updated.Endpoint != cfg.Endpoint {
		t.Fatalf("expected endpoint override to be preserved")
	}
	if updated.Model != cfg.Model {
		t.Fatalf("expected model override to be preserved")
	}
}
