package app

import (
	"testing"

	"github.com/slomin/sai/internal/settings"
)

func TestApplyPersistedSettingsPromotesLocalPreset(t *testing.T) {
	cfg := Config{
		Persisted: settings.Config{
			Mode: settings.ModeLocal,
		},
	}
	updated := applyPersistedSettings(cfg)
	if !updated.LocalPreset {
		t.Fatalf("expected local preset to be enabled from persisted settings")
	}
	if updated.LocalPresetSet {
		t.Fatalf("local preset should not count as CLI-provided")
	}
}

func TestApplyPersistedSettingsRespectsProvidedEndpoint(t *testing.T) {
	cfg := Config{
		Endpoint:         "http://cli",
		EndpointProvided: true,
		Persisted: settings.Config{
			Endpoint: "http://persisted",
		},
	}
	updated := applyPersistedSettings(cfg)
	if updated.Endpoint != "http://cli" {
		t.Fatalf("cli endpoint should win, got %s", updated.Endpoint)
	}
}

func TestApplyPersistedSettingsFillsCustomEndpointAndModel(t *testing.T) {
	cfg := Config{
		Persisted: settings.Config{
			Mode:     settings.ModeCustom,
			Endpoint: "http://custom",
			Model:    "custom-model",
		},
	}
	updated := applyPersistedSettings(cfg)
	if updated.Endpoint != "http://custom" {
		t.Fatalf("expected custom endpoint, got %s", updated.Endpoint)
	}
	if updated.Model != "custom-model" {
		t.Fatalf("expected custom model, got %s", updated.Model)
	}
}

func TestApplyPersistedSettingsAppliesAPIKey(t *testing.T) {
	cfg := Config{
		Persisted: settings.Config{
			APIKey: "persisted-key",
		},
	}
	updated := applyPersistedSettings(cfg)
	if updated.APIKey != "persisted-key" {
		t.Fatalf("expected api key from persisted settings, got %s", updated.APIKey)
	}
}

func TestApplyPersistedSettingsSkipsAPIKeyWhenProvided(t *testing.T) {
	cfg := Config{
		APIKey:         "cli-key",
		APIKeyProvided: true,
		Persisted: settings.Config{
			APIKey: "persisted-key",
		},
	}
	updated := applyPersistedSettings(cfg)
	if updated.APIKey != "cli-key" {
		t.Fatalf("expected cli key to win, got %s", updated.APIKey)
	}
}
