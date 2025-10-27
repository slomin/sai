package main

import (
	"context"
	"fmt"
	"log"
	"strings"

	appctx "github.com/slomin/sai/internal/context"
	"github.com/slomin/sai/internal/lm"
)

func main() {
	ctx := context.Background()
	client, err := lm.NewClient("http://192.168.1.90:8080/v1/chat/completions", "models/qwen3.gguf", "")
	if err != nil {
		log.Fatalf("new client: %v", err)
	}

	prompt1, err := appctx.ComposePrompt("Say hello.")
	if err != nil {
		log.Fatalf("compose prompt 1: %v", err)
	}
	history := []lm.ChatMessage{{Role: "user", Content: prompt1}}
	fmt.Println("--- First stream ---")
	err = client.StreamChat(ctx, "You are a helpful assistant.", history, func(update lm.StreamUpdate) error {
		if update.Content != "" {
			fmt.Print(update.Content)
		}
		return nil
	})
	fmt.Println()
	if err != nil {
		log.Fatalf("first stream: %v", err)
	}

	fmt.Println("\n--- Second stream ---")
	history = append(history, lm.ChatMessage{Role: "assistant", Content: strings.TrimSpace("Hello! How can I help? ")})
	prompt2, err := appctx.ComposePrompt("Say something else.")
	if err != nil {
		log.Fatalf("compose prompt 2: %v", err)
	}
	history = append(history, lm.ChatMessage{Role: "user", Content: prompt2})
	err = client.StreamChat(ctx, "You are a helpful assistant.", history, func(update lm.StreamUpdate) error {
		if update.Content != "" {
			fmt.Print(update.Content)
		}
		return nil
	})
	fmt.Println()
	if err != nil {
		log.Fatalf("second stream: %v", err)
	}

	fmt.Println("done")
}
