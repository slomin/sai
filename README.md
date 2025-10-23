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
- `sai ...` – free-form natural language; while the spinner shows activity the Dart CLI gathers context, redacts secrets, queries LM Studio, and only falls back to `sai-core` if needed. Structured LM replies surface in an interactive selector so you can paste the explanation or command straight into your prompt.

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
| `SAI_NO_SPINNER` | Set to disable the thinking spinner | _(unset)_ |
| `SAI_NO_MENU` | Disable the interactive explanation/command selector | _(unset)_ |
| `SAI_NO_CLIPBOARD` | Skip copying selections to the clipboard fallback | _(unset)_ |
| `SAI_HISTORY_FILE` | Fallback history file when wrapper stdout is absent | _(unset)_ |

## Development

- Run tests with `dart test` (requires Flutter/Dart SDK).
- Format and analyze via `dart format .` and `dart analyze`.
- The codebase targets Dart `>=3.2.0`, macOS focused; future roadmap includes PowerShell/fish snippets and richer context.
- LM Studio integration is on by default; adjust env vars above to point at a different local server. Disable the spinner with `SAI_NO_SPINNER=1` if you prefer silent mode.
- The interactive selector surfaces explanation/command choices and copies them to the macOS clipboard (unless `SAI_NO_CLIPBOARD=1`). If you want a convenience wrapper that simply forwards to the binary without glob expansion, source `scripts/rai.zsh`.

- The `FOR_CODING_AGENTS/sai.dart` file remains as a reference prototype—do not ship it; use the new Dart implementation instead.
- Try `scripts/demo_requests.sh [count]` for a quick smoke run; it cycles through sample prompts, measures per-call time, and prints summary statistics.

## rai (Rust TUI prototype)

Alongside the Dart CLI, the repository now hosts a Ratatui-based experiment in `rai/` that mirrors the same LM workflow but offers a richer in-terminal selector.

- Build it with `cargo build --release` inside `rai/` (Rust 1.90+ required); the binary is staged at `build/rai`.
- After each build, the helper script runs `codesign --force --sign - build/rai` so macOS trusts the CLI (the ad-hoc signature is enough for local use; replace `-` with a real identity if you have one).
- Runtime configuration honors the existing `SAI_LM_*` variables plus a few extras (`RAI_SYSTEM_PROMPT`, `RAI_NO_CLIPBOARD`, `RAI_LOG`).
- Invoke it the same way as `sai`, e.g. `rai "list hidden files"`, and use the highlighted menu to copy either the explanation or the recommended command.
- Launching `rai` with no arguments drops you into an inline prompt so you can type questions (including `?` or `'`) without wrestling with shell quoting.
- To avoid shell globbing, source `scripts/rai.zsh` (or create a similar alias in bash) which just runs the compiled binary with `noglob`.
- Add `--debug-performance` to skip the UI and print a formatted explanation/command directly—ideal for scripts or the new `scripts/rai_demo_requests.sh` smoke test runner.
