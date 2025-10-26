package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/slomin/sai/internal/app"
)

func main() {
	cfg := parseFlags()

	if err := app.Run(context.Background(), cfg); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func parseFlags() app.Config {
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
	defaultAPIKey := os.Getenv("SAI_LM_API_KEY")
	defaultSystemPrompt, systemPromptFromEnv := envString("RAI_SYSTEM_PROMPT")
	defaultLogFilter := envOrDefault("RAI_LOG", "info")
	defaultNoClipboard := envBool("RAI_NO_CLIPBOARD")
	defaultNoStream := envBool("SAI_NO_STREAM")

	flag.StringVar(&cfg.Endpoint, "endpoint", endpointDefault, "chat completion endpoint URL")
	flag.StringVar(&cfg.Model, "model", modelDefault, "model identifier to request")
	flag.StringVar(&cfg.APIKey, "api-key", defaultAPIKey, "optional API key or bearer token")
	flag.BoolVar(&cfg.LocalPreset, "local", false, "use the local LM Studio preset")
	flag.BoolVar(&cfg.LocalPreset, "l", false, "use the local LM Studio preset (alias)")
	flag.BoolVar(&cfg.DisableClipboard, "no-clipboard", defaultNoClipboard, "disable clipboard integration")
	flag.BoolVar(&cfg.DisableStream, "no-stream", defaultNoStream, "disable streaming chat output")
	flag.StringVar(&cfg.SystemPrompt, "system-prompt", defaultSystemPrompt, "custom system prompt (optional)")
	flag.StringVar(&cfg.LogFilter, "log-filter", defaultLogFilter, "log filter (zap-style)")
	flag.BoolVar(&cfg.DebugPerformance, "debug-performance", false, "print formatted output and skip interactive UI")
	flag.BoolVar(&cfg.Debug, "debug", false, "dump request/response JSON for LLM calls")
	flag.BoolVar(&cfg.GuessMode, "guess", false, "start intent-prediction chat mode")
	flag.BoolVar(&cfg.GuessMode, "g", false, "start intent-prediction chat mode (alias)")
	flag.BoolVar(&cfg.LongChat, "long-chat", false, "start a long-form chat with a minimal system prompt")
	flag.BoolVar(&cfg.LongChat, "lc", false, "start a long-form chat with a minimal system prompt (alias)")
	flag.BoolVar(&cfg.InteractiveHelp, "interactive-help", false, "open the interactive SAI help desk")
	flag.BoolVar(&cfg.InteractiveHelp, "ih", false, "open the interactive SAI help desk (alias)")

	flag.Parse()
	cfg.Args = flag.Args()

	cfg.APIKey = strings.TrimSpace(cfg.APIKey)
	cfg.SystemPrompt = strings.TrimSpace(cfg.SystemPrompt)
	if cfg.SystemPrompt == "" && systemPromptFromEnv {
		cfg.SystemPrompt = defaultSystemPrompt
	}

	var endpointFlagSet, modelFlagSet bool
	flag.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "endpoint":
			endpointFlagSet = true
		case "model":
			modelFlagSet = true
		}
	})

	cfg.EndpointProvided = endpointFlagSet || endpointFromEnv
	cfg.ModelProvided = modelFlagSet || modelFromEnv

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
