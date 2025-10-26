# Repository Guidelines

## Feedback Loop & Research Prerequisites
- **TDD first**: write or update tests, watch them fail, code the change, and re-run `go test ./...` until green.
- **Compile often**: `go build ./cmd/sai` or `./sai_deploy.sh` (both require elevated permissions) after non-trivial edits.
- **Context7 MCP required**: consult `/charmbracelet/bubbletea` and `/ggml-org/llama.cpp` before altering UI or streaming logic; summarize insights in PRs.

## Build, Test, and Development Commands
- `go test ./...` – runs the Go unit suite against the remote default endpoint; grant elevated permissions (`sudo` or CLI escalation) so caches can be created.
- `go build ./cmd/sai` – compiles the CLI into the repository root; reuse elevated privileges if the build cache complains.
- `./sai_deploy.sh` – produces `build/sai` and installs it to `/usr/local/bin/sai`; the script escalates via `sudo` automatically.

## Project Structure & Module Organization
- `go.mod` at the repository root declares the `github.com/slomin/sai-go` module.
- `cmd/sai`: CLI entrypoint and flag parsing.
- `internal/app`, `context`, `lm`, `ui`, `ui/chat`, `prompts`: state orchestration, context capture, LM client, Bubble Tea models, and system prompt text respectively.
- Tests live alongside implementations (`internal/*_test.go`). `build/` holds compiled binaries when `sai_deploy.sh` runs.

## Coding Style & Naming Conventions
- Always run `gofmt -w` on touched files.
- Use `internal/<module>` naming; exported identifiers UpperCamelCase, unexported lowerCamelCase.
- Keep Bubble Tea styling in helpers or future `internal/styles` package; avoid inline color literals.

## Testing Guidelines
- Tests use Go’s standard `testing` package and sit in `*_test.go`.
- Extend coverage when touching streaming, prompt composition, or Bubble Tea state machines; fail-first tests document regressions.
- Reviews require a fresh `go test ./...` run with elevated permissions if prompted.

## Commit & Pull Request Guidelines
- Use imperative, scoped commit messages (e.g., `chat: add streaming placeholder guard`).
- Pull requests should summarize behavior changes, call out impacted commands/environments, and list verification steps (`go test ./...`). Include screenshots or clips when modifying terminal UI output.

## Architecture Notes
- Streaming logic surfaces via `internal/lm.Client.StreamChat` (tested against the remote default endpoint) and UI handlers; keep cross-cutting helpers in `internal/util` when introduced.
- The CLI now targets the remote llama.cpp server by default; pass `-l`/`--local` for LM Studio. Update docs/tests accordingly when changing endpoints.
- See `opencode_reference_arch.md` for structural inspiration and planned refactors (themes, componentization, command registry).

## Documentation & Research Workflow
- Use the Context7 MCP integration for upstream docs (e.g., `/charmbracelet/bubbletea`, `/ggml-org/llama.cpp`) before making changes; this keeps guidance consistent with the libraries we mirror.
- Record any critical external references in PR descriptions so reviewers can trace design decisions quickly.
