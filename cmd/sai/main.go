package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
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

	defaultSystemPrompt, systemPromptFromEnv := envString("SAI_SYSTEM_PROMPT")
	defaultLogFilter := envOrDefault("SAI_LOG", "info")
	defaultNoClipboard := false
	defaultNoStream := envBool("SAI_NO_STREAM")

	fs := flag.NewFlagSet("sai", flag.ContinueOnError)
	fs.Usage = printUsage

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

	cfg.SystemPrompt = strings.TrimSpace(cfg.SystemPrompt)
	if cfg.SystemPrompt == "" && systemPromptFromEnv {
		cfg.SystemPrompt = defaultSystemPrompt
	}

	return cfg
}

func printUsage() {
	fmt.Fprintf(os.Stderr, `SAI - Streaming Assistant Interface

A terminal-based chat client for llama.cpp and OpenAI-compatible backends.

Usage:
  sai [prompt]                 Start chat with optional initial prompt
  sai -s, --settings           Configure endpoint and model
  sai -h, --help               Show this help message

Chat Modes:
  -g, --guess                  Intent prediction mode (with context)
  -lc, --long-chat             Long-form conversation mode
  -ih, --interactive-help      SAI help desk

Configuration:
  -s, --settings               Open interactive settings menu
                               (Configure endpoint, model, API key)

Options:
  --no-stream                  Disable streaming output
  --no-clipboard               Disable clipboard integration
  --system-prompt <text>       Custom system prompt
  --log-filter <level>         Log level (debug, info, warn, error)
  --debug                      Dump request/response JSON
  --debug-performance          Print formatted output without TUI

Environment Variables:
  SAI_SYSTEM_PROMPT            Custom system prompt
  SAI_LOG                      Log level filter
  SAI_NO_STREAM                Disable streaming (true/false)

Examples:
  sai                          Start interactive chat
  sai "how do I list files?"   Quick query
  sai -g                       Start intent prediction mode
  sai -s                       Configure LM Studio or remote endpoint

Configuration is stored in:
  macOS: ~/Library/Application Support/sai/config.json
  Linux: ~/.config/sai/config.json

`)
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
