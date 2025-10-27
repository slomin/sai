package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/slomin/sai/internal/app"
	"github.com/slomin/sai/internal/settings"
)

func main() {
	cfg := parseFlags(os.Args[1:])

	store, err := settings.NewStore()
	if err != nil {
		fmt.Fprintf(os.Stderr, "init settings store: %v\n", err)
		os.Exit(1)
	}

	persisted, err := store.Load()
	if err != nil {
		if errors.Is(err, settings.ErrCorruptConfig) || errors.Is(err, settings.ErrIncompatibleVersion) {
			fmt.Fprintf(os.Stderr, "warning: ignoring persisted settings (%v)\n", err)
		} else {
			fmt.Fprintf(os.Stderr, "read settings: %v\n", err)
			os.Exit(1)
		}
	} else {
		cfg.Persisted = persisted
	}
	cfg.SettingsStore = store

	if err := app.Run(context.Background(), cfg); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func parseFlags(args []string) app.Config {
	var cfg app.Config

	endpointDefault, endpointFromEnv := envString("SAI_LM_ENDPOINT")
	if endpointDefault == "" {
		endpointDefault = "http://192.168.1.90:8080/v1/chat/completions"
		endpointFromEnv = false
	}
	modelDefault, modelFromEnv := envString("SAI_LM_MODEL")
	if modelDefault == "" {
		modelDefault = "models/qwen3.gguf"
		modelFromEnv = false
	}
	defaultAPIKey, apiKeyFromEnv := envString("SAI_LM_API_KEY")
	defaultSystemPrompt, systemPromptFromEnv := envString("RAI_SYSTEM_PROMPT")
	defaultLogFilter := envOrDefault("RAI_LOG", "info")
	defaultNoClipboard := false
	defaultNoStream := envBool("SAI_NO_STREAM")

	fs := flag.NewFlagSet("sai", flag.ContinueOnError)
	fs.SetOutput(io.Discard)

	fs.StringVar(&cfg.Endpoint, "endpoint", endpointDefault, "chat completion endpoint URL")
	fs.StringVar(&cfg.Model, "model", modelDefault, "model identifier to request")
	fs.StringVar(&cfg.APIKey, "api-key", defaultAPIKey, "optional API key or bearer token")
	fs.BoolVar(&cfg.LocalPreset, "local", false, "use the local LM Studio preset")
	fs.BoolVar(&cfg.LocalPreset, "l", false, "use the local LM Studio preset (alias)")
	fs.BoolVar(&cfg.DisableClipboard, "no-clipboard", defaultNoClipboard, "disable clipboard integration")
	fs.BoolVar(&cfg.DisableStream, "no-stream", defaultNoStream, "disable streaming chat output")
	fs.StringVar(&cfg.SystemPrompt, "system-prompt", defaultSystemPrompt, "custom system prompt (optional)")
	fs.StringVar(&cfg.LogFilter, "log-filter", defaultLogFilter, "log filter (zap-style)")
	fs.BoolVar(&cfg.DebugPerformance, "debug-performance", false, "print formatted output and skip interactive UI")
	fs.BoolVar(&cfg.Debug, "debug", false, "dump request/response JSON for LLM calls")
	fs.BoolVar(&cfg.GuessMode, "guess", false, "start intent-prediction chat mode")
	fs.BoolVar(&cfg.GuessMode, "g", false, "start intent-prediction chat mode (alias)")
	fs.BoolVar(&cfg.LongChat, "long-chat", false, "start a long-form chat with a minimal system prompt")
	fs.BoolVar(&cfg.LongChat, "lc", false, "start a long-form chat with a minimal system prompt (alias)")
	fs.BoolVar(&cfg.InteractiveHelp, "interactive-help", false, "open the interactive SAI help desk")
	fs.BoolVar(&cfg.InteractiveHelp, "ih", false, "open the interactive SAI help desk (alias)")
	fs.BoolVar(&cfg.SettingsMode, "settings", false, "open the interactive settings menu")
	fs.BoolVar(&cfg.SettingsMode, "s", false, "open the interactive settings menu (alias)")

	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			os.Exit(0)
		}
		fmt.Fprintf(os.Stderr, "%v\n", err)
		os.Exit(2)
	}

	cfg.Args = fs.Args()

	cfg.APIKey = strings.TrimSpace(cfg.APIKey)
	cfg.SystemPrompt = strings.TrimSpace(cfg.SystemPrompt)
	if cfg.SystemPrompt == "" && systemPromptFromEnv {
		cfg.SystemPrompt = defaultSystemPrompt
	}

	var endpointFlagSet, modelFlagSet, apiKeyFlagSet, localFlagSet bool
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "endpoint":
			endpointFlagSet = true
		case "model":
			modelFlagSet = true
		case "api-key":
			apiKeyFlagSet = true
		case "local", "l":
			localFlagSet = true
		}
	})

	cfg.EndpointProvided = endpointFlagSet || endpointFromEnv
	cfg.ModelProvided = modelFlagSet || modelFromEnv
	cfg.APIKeyProvided = apiKeyFlagSet || apiKeyFromEnv
	cfg.LocalPresetSet = localFlagSet

	return cfg
}

func envOrDefault(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func envString(key string) (string, bool) {
	if value, ok := os.LookupEnv(key); ok {
		trimmed := strings.TrimSpace(value)
		if trimmed != "" {
			return trimmed, true
		}
	}
	return "", false
}

func envBool(key string) bool {
	value, ok := os.LookupEnv(key)
	if !ok {
		return false
	}
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}
