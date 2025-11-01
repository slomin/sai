package app

import (
	"strings"

	"github.com/slomin/sai/internal/settings"
)

// Config mirrors the existing Ratatui CLI options for the Bubble Tea port.
type Config struct {
	Endpoint         string
	Model            string
	APIKey           string
	GuessMode        bool
	LongChat         bool
	InteractiveHelp  bool
	DisableStream    bool
	DisableClipboard bool
	SystemPrompt     string
	LogFilter        string
	DebugPerformance bool
	Debug            bool
	Args             []string
	SettingsMode     bool
	Persisted        settings.Config
	SettingsStore    SettingsStore
}

// SettingsStore provides persistence for user preferences.
type SettingsStore interface {
	Save(settings.Config) error
	Path() string
}

func applyPersistedSettings(cfg Config) Config {
	persisted := cfg.Persisted

	trim := func(in string) string { return strings.TrimSpace(in) }

	// Always use persisted API key if available
	if key := trim(persisted.APIKey); key != "" {
		cfg.APIKey = key
	}

	// Always use persisted endpoint and model if available
	if endpoint := trim(persisted.Endpoint); endpoint != "" {
		cfg.Endpoint = endpoint
	}
	if model := trim(persisted.Model); model != "" {
		cfg.Model = model
	}

	return cfg
}
