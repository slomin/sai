package main

import (
	"os"
	"testing"
)

func TestParseFlagsSettingsMode(t *testing.T) {
	t.Cleanup(func() {
		resetEnv(t)
	})
	cfg := parseFlags([]string{"--settings"})
	if !cfg.SettingsMode {
		t.Fatalf("expected settings mode enabled")
	}
}

func TestParseFlagsTracksLocalPresetFlag(t *testing.T) {
	t.Cleanup(func() {
		resetEnv(t)
	})
	cfg := parseFlags([]string{"--local"})
	if !cfg.LocalPreset {
		t.Fatalf("local preset should be true")
	}
	if !cfg.LocalPresetSet {
		t.Fatalf("local preset flag should be marked as set")
	}
}

func TestParseFlagsMarksAPIKeyFromEnv(t *testing.T) {
	t.Cleanup(func() {
		resetEnv(t)
	})
	t.Setenv("SAI_LM_API_KEY", "env-key")
	cfg := parseFlags(nil)
	if cfg.APIKey != "env-key" {
		t.Fatalf("expected api key from env, got %s", cfg.APIKey)
	}
	if !cfg.APIKeyProvided {
		t.Fatalf("api key should be marked as provided via env")
	}
}

func resetEnv(t *testing.T) {
	t.Helper()
	os.Clearenv()
}
