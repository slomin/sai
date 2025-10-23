# sai – shell assistant frontend (macOS, Dart)

This repository hosts the shell-facing tooling for the `sai-core` coding assistant. It provides:

- A Dart CLI (`sai`) that gathers shell context and sends it to a local LLM endpoint (LM Studio by default) and, if desired, a `sai-core` binary.
- `sai init <shell>` to emit mac-friendly wrapper functions for zsh and bash.
- `sai doctor` to validate installation, context capture, and core connectivity.

## Quick start (macOS)

```bash
dart pub get
dart compile exe bin/sai.dart -o build/sai
sudo mv build/sai /usr/local/bin/sai
echo 'eval "$(sai init zsh)"' >> ~/.zshrc
```

Restart your shell; typing `sai how do I run tests?` now calls the wrapper, which collects recent history + `PWD` and sends a rich prompt to LM Studio (or another OpenAI-compatible endpoint). If `SAI_LM_DISABLED=1`, the CLI falls back to launching `sai-core` via `--json @-`.

## Commands

- `sai init <zsh|bash>` – print the shell function that captures history and delegates to the binary (use `eval "$(sai init zsh)"` in `~/.zshrc`).
- `sai doctor` – check that `sai-core` is reachable and that the current directory is readable. Non-zero exit codes highlight actionable failures.
- `sai ...` – free-form natural language; the wrapper forwards `--history-stdin` plus raw arguments, and the Dart CLI handles redaction, JSON packaging, and `sai-core` invocation.

## Environment knobs

| Variable | Purpose | Default |
| --- | --- | --- |
| `SAI_HISTORY_COUNT` | Limit the number of history entries kept | `10` |
| `SAI_NO_SEND` | Comma list of sections to drop (`history`, `pwd`, `listing`) | _(none)_ |
| `SAI_IGNORE_GLOBS` | Extra directory patterns to ignore (doctor snapshots) | _(none)_ |
| `SAI_MAX_LISTING` | Cap on directory entries for diagnostics | `5000` |
| `SAI_LM_ENDPOINT` | OpenAI-compatible chat endpoint | `http://localhost:1234/v1/chat/completions` |
| `SAI_LM_MODEL` | Model name advertised by LM Studio | `qwen3-vl-4b-instruct-mlx` |
| `SAI_LM_SYSTEM_PROMPT` | System message injected ahead of user/context | concise CLI helper prompt |
| `SAI_LM_TEMPERATURE` | Optional sampling temperature | _(unset)_ |
| `SAI_LM_TIMEOUT_SECONDS` | HTTP timeout for the LLM call | `15` |
| `SAI_LM_DISABLED` | Set to `1`/`true` to skip HTTP calls and rely on `sai-core` | _(unset)_ |
| `SAI_HISTORY_FILE` | Fallback history file when wrapper stdout is absent | _(unset)_ |

## Development

- Run tests with `dart test` (requires Flutter/Dart SDK).
- Format and analyze via `dart format .` and `dart analyze`.
- The codebase targets Dart `>=3.2.0`, macOS focused; future roadmap includes PowerShell/fish snippets and richer context.
- LM Studio integration is on by default; adjust env vars above to point at a different local server.

The `FOR_CODING_AGENTS/sai.dart` file remains as a reference prototype—do not ship it; use the new Dart implementation instead.
