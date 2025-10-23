## sai Front-End Implementation Plan (macOS, Dart)

- **Core contract in Dart**  
  Implement a shared library that defines the JSON payload schema, CLI argument handling for `--json`, and the exit-code contract (`0` success, `2` bad input, `3` context error, `4` LLM error). Cover with unit tests to prevent schema drift.

- **Shell init generator**  
  Build `sai init <shell>` in Dart that emits wrapper functions for macOS zsh (primary) and bash (secondary). Ensure wrappers treat all arguments as free-form text, grab the last 10 commands via `fc`/`history`, attach `PWD`, and forward JSON to `sai-core`.

- **CLI wrapper executable**  
  Extend the Dart `sai` binary to gather context (message, history, cwd), apply redaction filters, serialize JSON, and stream it to `sai-core` while propagating stdout/stderr and exit codes. Provide clear user-facing errors when `sai-core` is absent or misbehaves.

- **Context helpers**  
  Create Dart modules for history acquisition (stdin, live shell, fallback files), directory listing with ignore-glob support, size limits, and UTF-8-safe handling. Respect environment toggles such as `SAI_HISTORY_COUNT`, `SAI_IGNORE_GLOBS`, `SAI_NO_SEND`.

- **Diagnostics command**  
  Add `sai doctor` in Dart to verify shell integration output, check that `sai-core` is discoverable/executable, validate context collection, and offer actionable guidance when checks fail.

- **Testing on macOS**  
  Write Dart unit tests plus shell smoke tests that spawn `/bin/zsh` and `/bin/bash`, covering messages starting with `--`, empty history, large directories, and redaction behavior. Integrate into a mac-focused test script or CI job.

- **Documentation & packaging**  
  Update README with mac install steps (`eval "$(sai init zsh)"`), environment variables, privacy guardrails, and `sai doctor` usage. Package the Dart executables (`dart compile exe`) for distribution, noting mac-only support in this iteration.
