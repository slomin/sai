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

	appctx "github.com/sai-project/sai-go/internal/context"
	"github.com/sai-project/sai-go/internal/lm"
	"github.com/sai-project/sai-go/internal/prompts"
	"github.com/sai-project/sai-go/internal/ui"
	chatu "github.com/sai-project/sai-go/internal/ui/chat"
)

const (
	defaultSystemPrompt = prompts.StructuredPrompt

	remoteEndpoint = "http://192.168.1.90:8080/v1/chat/completions"
	remoteModel    = "models/qwen3.gguf"

	defaultIntentPrompt = "Please review the entire context snapshot and infer my most likely intent, highlighting relevant commands or next steps."
)

// Run orchestrates debug modes or the interactive Bubble Tea program.
func Run(ctx context.Context, cfg Config) error {
	if cfg.RemotePreset {
		cfg.Endpoint = remoteEndpoint
		cfg.Model = remoteModel
		fmt.Fprintf(os.Stderr, "using remote llama endpoint %s\n", cfg.Endpoint)
	}

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
		return runChat(ctx, client, launch.SystemPrompt, launch.Title, launch.AutoPrompt)
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

func runChat(ctx context.Context, client *lm.Client, systemPrompt string, title string, autoPrompt string) error {
	enterAltScreen(os.Stdout)
	defer leaveAltScreen(os.Stdout)

	program := chatu.NewProgram(chatu.Options{
		Context:      ctx,
		Client:       client,
		SystemPrompt: systemPrompt,
		Title:        title,
		AutoPrompt:   autoPrompt,
	})
	if _, err := program.Run(); err != nil {
		return fmt.Errorf("run chat ui: %w", err)
	}
	clearPromptLine()
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
	SystemPrompt string
	Title        string
	AutoPrompt   string
}

func selectChatLaunch(cfg Config, trimmedPrompt string) (chatLaunch, bool) {
	if cfg.GuessMode {
		return chatLaunch{
			SystemPrompt: resolveIntentPrompt(cfg.SystemPrompt),
			Title:        "SAI Intent Chat",
			AutoPrompt:   defaultIntentPrompt,
		}, true
	}
	if trimmedPrompt == "" {
		return chatLaunch{
			SystemPrompt: resolveChatPrompt(cfg.SystemPrompt),
			Title:        "SAI Chat",
			AutoPrompt:   "",
		}, true
	}
	return chatLaunch{}, false
}
