package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"time"

	"golang.org/x/term"

	appctx "github.com/slomin/sai/internal/context"
	"github.com/slomin/sai/internal/lm"
	"github.com/slomin/sai/internal/prompts"
	"github.com/slomin/sai/internal/ui"
	chatu "github.com/slomin/sai/internal/ui/chat"
	settingsui "github.com/slomin/sai/internal/ui/settings"
)

const (
	defaultSystemPrompt = prompts.StructuredPrompt

	remoteEndpoint = "http://192.168.1.90:8080/v1/chat/completions"
	remoteModel    = "models/qwen3.gguf"
	localEndpoint  = "http://localhost:1234/v1/chat/completions"
	localModel     = "qwen3-vl-4b-instruct-mlx"

	defaultIntentPrompt           = "Please review the entire context snapshot and infer my most likely intent, highlighting relevant commands or next steps."
	defaultInteractiveHelpKickoff = "Introduce the SAI CLI, greet the user warmly, and list the key features and flags."
)

// Run orchestrates debug modes or the interactive Bubble Tea program.
func Run(ctx context.Context, cfg Config) error {
	if cfg.SettingsMode {
		return runSettings(ctx, cfg)
	}

	cfg = resolveEndpointAndModel(cfg)
	announceEndpointSelection(cfg)

	initLogging(cfg.LogFilter)

	client, err := lm.NewClient(cfg.Endpoint, cfg.Model, cfg.APIKey)
	if err != nil {
		return fmt.Errorf("init client: %w", err)
	}

	systemPrompt := resolveSystemPrompt(cfg.SystemPrompt)

	if cfg.Debug || cfg.DebugPerformance {
		dumpDebug := cfg.Debug
		if err := runDebug(ctx, cfg, client, systemPrompt, dumpDebug); err != nil {
			return err
		}
		return nil
	}

	pendingPrompt, err := initialPromptFromArgs(cfg)
	if err != nil {
		return fmt.Errorf("read prompt: %w", err)
	}

	if !isTerminal(os.Stdout.Fd()) {
		if err := runHeadless(ctx, client, systemPrompt, pendingPrompt); err != nil {
			return fmt.Errorf("headless run: %w", err)
		}
		return nil
	}

	trimmedPrompt := strings.TrimSpace(pendingPrompt)
	if launch, ok := selectChatLaunch(cfg, trimmedPrompt); ok {
		return runChat(ctx, client, launch, !cfg.DisableStream)
	}

	enterAltScreen(os.Stdout)
	defer leaveAltScreen(os.Stdout)

	program := ui.NewProgram(ui.Options{
		Context:          ctx,
		Client:           client,
		SystemPrompt:     systemPrompt,
		DisableClipboard: cfg.DisableClipboard,
		PendingPrompt:    pendingPrompt,
	})
	if _, err := program.Run(); err != nil {
		return fmt.Errorf("run program: %w", err)
	}
	clearPromptLine()

	return nil
}

func isTerminal(fd uintptr) bool {
	return term.IsTerminal(int(fd))
}

func resolveSystemPrompt(custom string) string {
	if strings.TrimSpace(custom) != "" {
		return custom
	}
	return defaultSystemPrompt
}

func resolveLongChatPrompt(custom string) string {
	if strings.TrimSpace(custom) != "" {
		return custom
	}
	return prompts.LongChatPrompt
}

func resolveInteractiveHelpPrompt(custom string) string {
	if strings.TrimSpace(custom) != "" {
		return custom
	}
	return prompts.InteractiveHelpPrompt
}

func resolveEndpointAndModel(cfg Config) Config {
	cfg = applyPersistedSettings(cfg)

	endpointBlank := strings.TrimSpace(cfg.Endpoint) == ""
	modelBlank := strings.TrimSpace(cfg.Model) == ""

	if cfg.LocalPreset {
		if !cfg.EndpointProvided || endpointBlank {
			cfg.Endpoint = localEndpoint
		}
		if !cfg.ModelProvided || modelBlank {
			cfg.Model = localModel
		}
		return cfg
	}

	if endpointBlank {
		cfg.Endpoint = remoteEndpoint
	}
	if modelBlank {
		cfg.Model = remoteModel
	}
	return cfg
}

func announceEndpointSelection(cfg Config) {
	switch {
	case cfg.LocalPreset && cfg.Endpoint == localEndpoint:
		fmt.Fprintf(os.Stderr, "using local LM Studio endpoint %s\n", cfg.Endpoint)
	case !cfg.LocalPreset && cfg.Endpoint == remoteEndpoint:
		fmt.Fprintf(os.Stderr, "using remote llama endpoint %s\n", cfg.Endpoint)
	default:
		fmt.Fprintf(os.Stderr, "using configured endpoint %s\n", cfg.Endpoint)
	}
}

func runSettings(ctx context.Context, cfg Config) error {
	return runSettingsWithRunner(ctx, cfg, settingsui.Run)
}

func runSettingsWithRunner(ctx context.Context, cfg Config, runner func(settingsui.Options) (settingsui.Result, error)) error {
	if cfg.SettingsStore == nil {
		return errors.New("settings store not configured")
	}

	opts := settingsui.Options{
		Context:        ctx,
		Current:        cfg.Persisted,
		RemoteEndpoint: remoteEndpoint,
		RemoteModel:    remoteModel,
		LocalEndpoint:  localEndpoint,
		LocalModel:     localModel,
	}

	result, err := runner(opts)
	if err != nil {
		return fmt.Errorf("settings ui: %w", err)
	}
	if !result.Saved {
		fmt.Fprintln(os.Stderr, "settings unchanged")
		return nil
	}
	if err := cfg.SettingsStore.Save(result.Config); err != nil {
		return fmt.Errorf("save settings: %w", err)
	}
	if result.Config != cfg.Persisted {
		fmt.Fprintf(os.Stderr, "settings saved to %s\n", cfg.SettingsStore.Path())
	}
	return nil
}

func runDebug(ctx context.Context, cfg Config, client *lm.Client, systemPrompt string, dumpDebug bool) error {
	prompt, err := initialPromptFromArgs(cfg)
	if err != nil {
		return err
	}
	trimmed := strings.TrimSpace(prompt)
	if trimmed == "" {
		return errors.New("prompt required for debug modes")
	}

	composed, err := appctx.ComposePrompt(trimmed)
	if err != nil {
		return fmt.Errorf("compose prompt: %w", err)
	}

	if dumpDebug {
		preview := map[string]any{
			"model": cfg.Model,
			"messages": []map[string]string{
				{"role": "system", "content": systemPrompt},
				{"role": "user", "content": composed},
			},
			"temperature": 0.2,
		}
		data, _ := json.MarshalIndent(preview, "", "  ")
		fmt.Println("--- Request --------------------------------------------------")
		fmt.Println(string(data))
		fmt.Println()
	}

	callCtx := ctx
	if callCtx == nil {
		callCtx = context.Background()
	}

	started := time.Now()
	result, err := client.Complete(callCtx, systemPrompt, composed)
	if err != nil {
		return err
	}
	elapsed := time.Since(started).Seconds()

	fmt.Printf("Prompt: %s\n\n", trimmed)
	fmt.Println("Explanation:")
	for _, line := range strings.Split(strings.TrimSpace(result.Structured.Explanation), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		fmt.Printf("  %s\n", line)
	}

	if cmd := strings.TrimSpace(result.Structured.RecommendedCommand); cmd != "" {
		fmt.Println()
		fmt.Println("Recommended Command:")
		fmt.Printf("  %s\n", cmd)
	}

	fmt.Println()
	fmt.Printf("[Total Response Time] %.3fs\n", elapsed)

	if result.Usage != nil {
		switch {
		case result.Usage.TotalTokens != nil:
			fmt.Printf("Usage: total %d tokens\n", *result.Usage.TotalTokens)
		case result.Usage.PromptTokens != nil || result.Usage.CompletionTokens != nil:
			fmt.Print("Usage:")
			if result.Usage.PromptTokens != nil {
				fmt.Printf(" prompt %d", *result.Usage.PromptTokens)
			}
			if result.Usage.CompletionTokens != nil {
				fmt.Printf(" · completion %d", *result.Usage.CompletionTokens)
			}
			fmt.Println(" tokens")
		}
	}

	if dumpDebug {
		fmt.Println()
		fmt.Println("--- Raw Response --------------------------------------------")
		var pretty map[string]any
		if err := json.Unmarshal([]byte(result.RawResponse), &pretty); err == nil {
			data, _ := json.MarshalIndent(pretty, "", "  ")
			fmt.Println(string(data))
		} else {
			fmt.Println(result.RawResponse)
		}
	}

	if cfg.DebugPerformance {
		cmd := strings.TrimSpace(result.Structured.RecommendedCommand)
		if cmd == "" {
			cmd = "# " + strings.TrimSpace(result.Structured.Explanation)
		}
		if cmd != "" {
			fmt.Fprintln(os.Stdout, cmd)
		}
	}

	return nil
}

func initialPromptFromArgs(cfg Config) (string, error) {
	if len(cfg.Args) > 0 {
		return strings.Join(cfg.Args, " "), nil
	}

	info, err := os.Stdin.Stat()
	if err != nil {
		return "", err
	}
	if (info.Mode() & os.ModeCharDevice) != 0 {
		return "", nil
	}

	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		return "", err
	}
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" {
		return "", nil
	}
	return trimmed, nil
}

func runHeadless(ctx context.Context, client *lm.Client, systemPrompt, pendingPrompt string) error {
	prompt := strings.TrimSpace(pendingPrompt)
	if prompt == "" {
		return nil
	}

	composed, err := appctx.ComposePrompt(prompt)
	if err != nil {
		return fmt.Errorf("compose prompt: %w", err)
	}

	callCtx := ctx
	if callCtx == nil {
		callCtx = context.Background()
	}

	result, err := client.Complete(callCtx, systemPrompt, composed)
	if err != nil {
		return err
	}

	output := strings.TrimSpace(result.Structured.RecommendedCommand)
	if output == "" {
		explanation := strings.TrimSpace(result.Structured.Explanation)
		if explanation != "" {
			output = "# " + explanation
		}
	}

	if output != "" {
		fmt.Println(output)
	}

	return nil
}

func runChat(ctx context.Context, client *lm.Client, launch chatLaunch, streamEnabled bool) error {
	enterAltScreen(os.Stdout)

	includeCtx := launch.IncludeContext
	var contextWindow *int
	if launch.ShowContext {
		lookupCtx := ctx
		if lookupCtx == nil {
			lookupCtx = context.Background()
		}
		lookupCtx, cancel := context.WithTimeout(lookupCtx, 2*time.Second)
		defer cancel()
		if limit, err := client.ContextWindow(lookupCtx); err == nil && limit > 0 {
			contextWindow = &limit
		} else if err != nil {
			slog.Debug("chat: context window lookup failed", "err", err)
		}
	}

	program := chatu.NewProgram(chatu.Options{
		Context:            ctx,
		Client:             client,
		SystemPrompt:       launch.SystemPrompt,
		Title:              launch.Title,
		AutoPrompt:         launch.AutoPrompt,
		Stream:             streamEnabled,
		IncludeContext:     &includeCtx,
		DisplayContext:     launch.ShowContext,
		ContextWindow:      contextWindow,
		AutoPromptInternal: launch.AutoPromptInternal,
	})
	finalModel, err := program.Run()
	leaveAltScreen(os.Stdout)
	clearPromptLine()
	if err != nil {
		return fmt.Errorf("run chat ui: %w", err)
	}
	if snippet, ok := chatu.SelectedSnippet(finalModel); ok {
		fmt.Println()
		fmt.Print(snippet)
		if !strings.HasSuffix(snippet, "\n") {
			fmt.Println()
		}
	}
	return nil
}

func initLogging(filter string) {
	level := slog.LevelInfo
	switch strings.ToLower(strings.TrimSpace(filter)) {
	case "debug", "trace":
		level = slog.LevelDebug
	case "warn", "warning":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	}

	handler := slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		Level: level,
	})
	slog.SetDefault(slog.New(handler))
}

func clearPromptLine() {
	if !isTerminal(os.Stdout.Fd()) {
		return
	}

	_, _ = fmt.Fprint(os.Stdout, "\r\x1b[2K")
}

func resolveChatPrompt(custom string) string {
	if strings.TrimSpace(custom) != "" {
		return custom
	}
	return prompts.ChatDeepPrompt
}

func resolveIntentPrompt(custom string) string {
	if strings.TrimSpace(custom) != "" {
		return custom
	}
	return prompts.ChatIntentPrompt
}

func enterAltScreen(out *os.File) {
	if out == nil {
		return
	}
	if !isTerminal(out.Fd()) {
		return
	}
	_, _ = fmt.Fprint(out, "\x1b[?1049h")
}

func leaveAltScreen(out *os.File) {
	if out == nil {
		return
	}
	if !isTerminal(out.Fd()) {
		return
	}
	_, _ = fmt.Fprint(out, "\x1b[?1049l")
}

type chatLaunch struct {
	SystemPrompt       string
	Title              string
	AutoPrompt         string
	IncludeContext     bool
	ShowContext        bool
	AutoPromptInternal bool
}

func selectChatLaunch(cfg Config, trimmedPrompt string) (chatLaunch, bool) {
	if cfg.GuessMode {
		return chatLaunch{
			SystemPrompt:       resolveIntentPrompt(cfg.SystemPrompt),
			Title:              "SAI Intent Chat",
			AutoPrompt:         defaultIntentPrompt,
			IncludeContext:     true,
			ShowContext:        false,
			AutoPromptInternal: false,
		}, true
	}
	if cfg.InteractiveHelp {
		return chatLaunch{
			SystemPrompt:       resolveInteractiveHelpPrompt(cfg.SystemPrompt),
			Title:              "SAI Help Desk",
			AutoPrompt:         defaultInteractiveHelpKickoff,
			IncludeContext:     false,
			ShowContext:        false,
			AutoPromptInternal: true,
		}, true
	}
	if cfg.LongChat {
		return chatLaunch{
			SystemPrompt:       resolveLongChatPrompt(cfg.SystemPrompt),
			Title:              "SAI Long Chat",
			AutoPrompt:         "",
			IncludeContext:     false,
			ShowContext:        true,
			AutoPromptInternal: false,
		}, true
	}
	if trimmedPrompt == "" {
		return chatLaunch{
			SystemPrompt:       resolveChatPrompt(cfg.SystemPrompt),
			Title:              "SAI Chat",
			AutoPrompt:         "",
			IncludeContext:     true,
			ShowContext:        false,
			AutoPromptInternal: false,
		}, true
	}
	return chatLaunch{}, false
}
