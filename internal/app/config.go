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
	LocalPreset      bool
	LocalPresetSet   bool
	GuessMode        bool
	LongChat         bool
	InteractiveHelp  bool
	EndpointProvided bool
	ModelProvided    bool
	APIKeyProvided   bool
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

	if !cfg.APIKeyProvided {
		if key := trim(persisted.APIKey); key != "" {
			cfg.APIKey = key
		}
	}

	if !cfg.LocalPresetSet {
		switch persisted.Mode {
		case settings.ModeLocal:
			cfg.LocalPreset = true
		case settings.ModeRemote:
			cfg.LocalPreset = false
		}
	}

	if !cfg.EndpointProvided {
		switch persisted.Mode {
		case settings.ModeCustom:
			if endpoint := trim(persisted.Endpoint); endpoint != "" {
				cfg.Endpoint = endpoint
			}
		case settings.ModeLocal, settings.ModeRemote:
			if endpoint := trim(persisted.Endpoint); endpoint != "" {
				cfg.Endpoint = endpoint
			}
		}
	}

	if !cfg.ModelProvided {
		switch persisted.Mode {
		case settings.ModeCustom:
			if model := trim(persisted.Model); model != "" {
				cfg.Model = model
			}
		case settings.ModeLocal, settings.ModeRemote:
			if model := trim(persisted.Model); model != "" {
				cfg.Model = model
			}
		}
	}

	return cfg
}
