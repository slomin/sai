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

## Installation

### Quick Install (Recommended)

```bash
curl -sSL https://raw.githubusercontent.com/slomin/sai/main/install.sh | bash
```

This script:
- Detects your platform (macOS/Linux, ARM64/AMD64)
- Downloads the latest release
- Installs to `~/.local/bin/sai`
- Removes macOS quarantine attributes automatically

### Manual Installation

Download the latest release from [GitHub Releases](https://github.com/slomin/sai/releases):

**macOS:**
```bash
# Apple Silicon (M1/M2/M3)
curl -L -o sai https://github.com/slomin/sai/releases/latest/download/sai-darwin-arm64

# Intel Mac
curl -L -o sai https://github.com/slomin/sai/releases/latest/download/sai-darwin-amd64

chmod +x sai
mkdir -p ~/.local/bin
mv sai ~/.local/bin/

# Remove quarantine attribute (prevents macOS Gatekeeper blocking)
xattr -d com.apple.quarantine ~/.local/bin/sai
```

**Linux:**
```bash
# AMD64
curl -L -o sai https://github.com/slomin/sai/releases/latest/download/sai-linux-amd64

# ARM64
curl -L -o sai https://github.com/slomin/sai/releases/latest/download/sai-linux-arm64

chmod +x sai
sudo mv sai /usr/local/bin/
```

### Build from Source

```bash
git clone https://github.com/slomin/sai.git
cd sai
go build ./cmd/sai
./sai --help
```

## Configuration

Configure your LM Studio or llama.cpp endpoint using the interactive settings menu:

```bash
sai --settings    # or sai -s
```

This will save your configuration to:
- **macOS**: `~/Library/Application Support/sai/config.json`
- **Linux**: `~/.config/sai/config.json`

## Usage

```bash
sai                          # Start interactive chat
sai "how do I list files?"   # Quick query
sai -g                       # Intent prediction mode (with context)
sai -lc                      # Long-form conversation
sai --help                   # Show all options
```

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

## Environment Variables

- `SAI_SYSTEM_PROMPT` – Custom system prompt
- `SAI_LOG` – Log level (debug, info, warn, error)
- `SAI_NO_STREAM` – Disable streaming (true/false)
- `GLAMOUR_STYLE` – Markdown theme (light, dark, dracula, etc.)

Example:
```bash
export GLAMOUR_STYLE=light
export SAI_LOG=debug
sai
```

## Testing

Run the test suite:
```bash
go test ./...
```

To test clipboard fallback behavior:
```bash
sai --no-clipboard
```

For deeper architectural guidance, refer to `AGENTS.md` and
`opencode_reference_arch.md`.
