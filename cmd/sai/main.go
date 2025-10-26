package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/sai-project/sai-go/internal/app"
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

	defaultEndpoint := envOrDefault("SAI_LM_ENDPOINT", "http://192.168.1.90:8080/v1/chat/completions")
	defaultModel := envOrDefault("SAI_LM_MODEL", "models/qwen3.gguf")
	defaultAPIKey := os.Getenv("SAI_LM_API_KEY")
	defaultSystemPrompt := os.Getenv("RAI_SYSTEM_PROMPT")
	defaultLogFilter := envOrDefault("RAI_LOG", "info")
	defaultNoClipboard := envBool("RAI_NO_CLIPBOARD")
	defaultNoStream := envBool("SAI_NO_STREAM")

	flag.StringVar(&cfg.Endpoint, "endpoint", defaultEndpoint, "chat completion endpoint URL")
	flag.StringVar(&cfg.Model, "model", defaultModel, "model identifier to request")
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

	flag.Parse()
	cfg.Args = flag.Args()

	cfg.APIKey = strings.TrimSpace(cfg.APIKey)
	cfg.SystemPrompt = strings.TrimSpace(cfg.SystemPrompt)

	return cfg
}

func envOrDefault(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
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
