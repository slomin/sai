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

func TestParseFlagsDoesNotSetEndpointFromFlags(t *testing.T) {
	t.Cleanup(func() {
		resetEnv(t)
	})
	cfg := parseFlags([]string{})
	// Endpoint should be empty when not provided by persisted settings
	if cfg.Endpoint != "" {
		t.Fatalf("endpoint should not be set from flags, got %s", cfg.Endpoint)
	}
}

func TestParseFlagsDoesNotSetModelFromFlags(t *testing.T) {
	t.Cleanup(func() {
		resetEnv(t)
	})
	cfg := parseFlags([]string{})
	// Model should be empty when not provided by persisted settings
	if cfg.Model != "" {
		t.Fatalf("model should not be set from flags, got %s", cfg.Model)
	}
}

func resetEnv(t *testing.T) {
	t.Helper()
	os.Clearenv()
}
