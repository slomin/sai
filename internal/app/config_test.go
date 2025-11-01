package app

import (
	"testing"

	"github.com/slomin/sai/internal/settings"
)

func TestApplyPersistedSettingsFillsEndpointAndModel(t *testing.T) {
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

func TestApplyPersistedSettingsDoesNotOverwriteExisting(t *testing.T) {
	cfg := Config{
		Endpoint: "http://already-set",
		Model:    "already-set-model",
		Persisted: settings.Config{
			Endpoint: "http://persisted",
			Model:    "persisted-model",
		},
	}
	updated := applyPersistedSettings(cfg)
	// Persisted settings always win
	if updated.Endpoint != "http://persisted" {
		t.Fatalf("expected persisted endpoint to overwrite, got %s", updated.Endpoint)
	}
	if updated.Model != "persisted-model" {
		t.Fatalf("expected persisted model to overwrite, got %s", updated.Model)
	}
}
