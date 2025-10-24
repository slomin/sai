# Repository Guidelines

## Project Structure & Module Organization
The Dart CLI entrypoint lives in `bin/sai.dart`. Core logic sits in `lib/` (public API in `lib/sai.dart`, supporting modules in `lib/src/...` for context collection, LM client, init templates, and UI helpers). Tests reside in `test/` mirroring module names via `_test.dart`. Rust-based TUI prototype is in `rai/` (cargo workspace) and shares build outputs in `build/`. Scripts and utilities are under `scripts/`, and generated binaries land in `build/`. Keep reference artifacts (`FOR_CODING_AGENTS/`) untouched unless explicitly updating documentation.

## Build, Test, and Development Commands
Run `dart pub get` once per dependency change. `dart compile exe bin/sai.dart -o build/sai` produces the CLI binary; follow with `sudo mv build/sai /usr/local/bin/sai` when installing locally. Use `dart test` for the unit suite, `dart analyze` for static analysis, and `dart format .` before sending patches. The `scripts/demo_requests.sh` and `scripts/rai_demo_requests.sh` scripts provide smoke checks against local LM endpoints. Inside `rai/`, run `cargo build --release` to recreate the Ratatui binary, which is staged at `build/rai`.

## Coding Style & Naming Conventions
Adhere to the recommended lints from `package:lints`; the repo enforces `prefer_single_quotes` and standard Dart formatting (two-space indent, trailing commas for multiline). Name files with snake_case (`context_collector.dart`, `history_test.dart`). Keep public APIs documented with concise doc comments and prefer small focused classes/functions under `lib/src`.

## Testing Guidelines
Add or update `_test.dart` companions in `test/` whenever touching logic in `lib/src`. Favor deterministic fixtures for history, listings, and HTTP mocks, maintaining parity with existing test helpers. Aim to cover new branches and error paths; if a scenario cannot be tested, note the rationale in the PR. Run `dart test` locally before requesting review and include relevant command output when bugs are fixed.

## Commit & Pull Request Guidelines
Recent commits are short lowercase placeholders (`wipN`); expand on that by using imperative, scoped messages (e.g., `cli: tighten context redaction`). Squash noisy fixups before pushing. Pull requests should describe the behavioral change, list verification steps (`dart test`, `dart analyze`, cargo builds when relevant), and reference any tracked issues. Include screenshots or terminal captures when altering CLI UX or doctor output, and call out configuration impacts (env vars, shell wrappers).

