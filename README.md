# sai – Streaming Assistant Interface

`sai` is a Bubble Tea–powered chat client for working with llama.cpp and other
OpenAI-compatible backends. The current session focused on polishing the chat
experience, so this README highlights the behaviours you can now rely on when
running the CLI.

## Highlights

- **Snappy startup** – Markdown rendering no longer probes the terminal for its
  background colour. Opening chat views is immediate even inside multiplexers
  or when OSC queries are blocked.
- **Live streaming telemetry** – The footer displays `tok/s` using
  llama.cpp’s `timings.predicted_per_second` metadata whenever it is available.
  When the server omits the field we fall back to a local cadence estimate.
- **Snippet workflow upgrades**
  - `Tab` cycles through assistant code fences. The hint only appears when a
    selectable fence exists.
  - Selected snippets are highlighted inline (`▶ Snippet selected`) so you can
    confirm the exact block that will be copied.
  - `Enter` copies the highlighted fence; `Esc` cancels the selection.
  - Clipboard write failures (e.g. headless hosts) keep the UI open and display
    the snippet inline with a red fallback banner instead of quitting.
- **Theme control** – Respect the `GLAMOUR_STYLE` environment variable
  (e.g. `light`, `dark`, `dracula`). Because we skip auto-detection for speed,
  set this explicitly if you prefer a light theme.

## Usage

```bash
go build ./cmd/sai          # build the CLI
./sai --stream              # start a streaming chat session

# Optional environment configuration
export GLAMOUR_STYLE=light  # choose a Glamour preset
```

### Installation shortcut

`./sai_deploy.sh` compiles the binary to `build/sai`, installs it to
`/usr/local/bin/sai`, and then ad-hoc signs the executable while clearing
macOS Gatekeeper quarantine/provenance attributes. This avoids the
`zsh: killed sai` failure on systems where Developer Mode is disabled. If you
install manually, mirror those `codesign`/`xattr` steps.

### Keyboard Shortcuts

| Key            | Action                                  |
| -------------- | --------------------------------------- |
| `Enter`        | Submit prompt / copy selected snippet   |
| `Esc`/`Ctrl+C` | Quit                                    |
| `PgUp/PgDn`    | Scroll transcript                       |
| `Alt+Up/Down`  | Scroll one line                         |
| `Alt+C`        | Copy the last assistant reply           |
| `Tab`          | Cycle assistant code snippets (if any)  |

## Testing

- `go test ./...` – run the Go unit suite (requires elevated permissions in
  sandboxed environments).
- Python integration tests are not yet included; see `project_progress/…` for
  the proposed harness if you plan to add them.

## Environment Notes

- To enforce the clipboard fallback path during testing, run with
  `--no-clipboard`.
- The chat client targets the remote llama.cpp server by default. Use
  `--local` to connect to LM Studio instead.

For deeper architectural guidance, refer to `AGENTS.md` and
`opencode_reference_arch.md`.
