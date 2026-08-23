# Opencode Reference Architecture Notes

This document captures the architectural patterns used in the `sst/opencode` Bubble Tea application and highlights ideas we can adopt (or adapt) for the Go-based `sai` CLI.

## 1. High-Level Layout

- **Module root**: `packages/tui/` is a self-contained Go module (`github.com/sst/opencode`) with `cmd/` for entrypoints and `internal/` for implementation details.
- **Entry program**: `cmd/opencode/main.go` wires configuration, HTTP clients, logging, and Bubble Tea program initialization.
- **Internal tree**: split by concern –
  - `internal/app`: long-lived application state, messages, session orchestration, prompt helpers.
  - `internal/tui`: the top-level Bubble Tea model, layout wiring, and event handling.
  - `internal/components`: reusable Bubble Tea components (chat view, dialogs, status bar, toast manager, etc.).
  - `internal/completions`, `internal/commands`, `internal/layout`, `internal/theme`, `internal/styles`, `internal/clipboard`, `internal/util`, `internal/api`.
  - Lower-level utilities such as `internal/viewport`, `internal/id`, and `internal/attachment`.
- **Input abstraction**: `packages/tui/input/` overrides Charm’s `x/input` module to manage terminal input quirks consistently across platforms.

## 2. Key Patterns Worth Adopting

### 2.1 Clear Separation of Responsibilities
- **App vs. UI**: `internal/app` owns state transitions, configuration, system prompt material, and domain logic; `internal/tui` focuses on Bubble Tea updates and visuals.
- **Componentization**: Each UI widget lives in `internal/components/...`, exposing a `Component` interface with `Init`, `Update`, `View`, and local state. This makes reuse and testing easier.
- **Command registry**: Keyboard shortcuts and command palette actions are defined centrally (`internal/commands`) and dispatched through helper utilities.

_Action for sai_: Move toward a layered layout under `internal/`, e.g.:
```
internal/
  app/               // state, config, prompt orchestration
  tui/               // top-level Bubble Tea model + program wiring
  components/chat/   // chat viewport + editor
  components/status/ // status/footer widget
  theme/             // theme manager
  styles/            // lipgloss helpers
  commands/          // key binding + command registry
  util/              // shared helpers (e.g., logging hooks)
```

### 2.2 System Prompt & Prompt Serialization
- Prompts are data objects (`internal/app/prompt.go`) that combine text plus rich attachments (files, symbols, agents). They can convert to/from the API’s message format.
- System prompt configuration flows from multiple sources:
  - Remote config (`Config.Get`) specifies theme and keybind defaults.
  - Environment variables override config (e.g., `OPENCODE_THEME`).
  - Agent metadata selects initial model and prompt.

_Action for sai_: Encapsulate prompt building logic in an `internal/app` helper (struct + serializers) instead of spreading prompt composition across UI/chat code. Keep system prompt resolution separate from the Bubble Tea model, allowing headless/stream modes to reuse it.

### 2.3 Theme & Style Management
- Themes load in priority order: embedded defaults → user config → project repo → current workspace. Implementation uses `embed.FS` plus JSON descriptors (`internal/theme/loader.go`).
- Colors represented via `lipgloss/v2/compat.AdaptiveColor` to support dark/light backgrounds automatically.
- `internal/theme` exposes an interface with semantic color getters (Primary, Border, DiffAdded, etc.).
- `internal/styles` builds lipgloss styles using the active theme, keeping rendering logic consistent and centralized.

_Action for sai_: Introduce a simple theme package leveraging AdaptiveColor. Even if we ship a single theme initially, structuring colors like `theme.Primary()` prevents hard-coded hex constants in the chat view and allows future theming/extensions.

### 2.4 Event & API Handling
- The main program uses `errgroup.Group` to parallelize initial HTTP requests (project, agents, paths).
- A streaming goroutine listens to SSE events and forwards them to the Bubble Tea program via `program.Send(evt)`. This keeps I/O out of the `Update` loop.
- Clipboard initialization runs in a background goroutine, and errors are logged via slog without crashing the UI.

_Action for sai_: When we add richer UI (beyond chat), adopt a similar pattern—`app.New` drafts state, while the Bubble Tea model receives events over channels or `program.Send`. For streaming completions we already do this; align the pattern with a dedicated event handler struct.

### 2.5 Testing & Utilities
- `internal/theme/loader_test.go`, `internal/app/app_test.go`, etc., cover core behaviors (state loading, theme parsing). Most components have small, focused tests.
- Utilities like `internal/util` provide logging adapters (`NewAPILogHandler`), path helpers, OS detection, and `CmdHandler` functions for command dispatch.

_Action for sai_: Expand tests around new structural packages (theme loading, commands). Provide small helper packages (e.g., `internal/util`) instead of embedding helpers in unrelated modules.

## 3. Additional Observations

- **Translations**: The Go TUI does not implement an i18n layer; everything is English. No immediate patterns to adopt here.
- **Input handling**: Their custom `input` package (vendored `github.com/charmbracelet/x/input`) enables precise control over terminal sequences and mouse handling. For sai, the standard Bubble Tea input works today, but if we expand features, having a dedicated input layer could simplify cross-terminal quirks.
- **Configuration**: Opencode leans on remote config plus local overrides, storing TUI state on disk (`~/.opencode/tui`). If we introduce persistent preferences (e.g., stream enabled, theme choice), replicate the pattern via a small state file in `$XDG_CONFIG_HOME/sai/`.
- **Component communication**: The top-level model owns modal/dialog state, delegating to components and merging their `Init/Update/View` outputs. Maintaining this architecture avoids large, monolithic `Update` methods.

## 4. Recommended Next Steps for `sai`

1. **Refactor package layout**:
   - Create `internal/components/chat` to host the chat view logic (currently in `internal/ui/chat`).
   - Introduce `internal/tui` as the top-level program orchestrator; keep `internal/ui` for legacy until migration is done.
   - Move context/prompt helpers into `internal/app` alongside config and state management.

2. **Establish a theme subsystem**:
   - Define a `theme.Theme` interface returning AdaptiveColor values.
   - Add a loader with a default palette (single JSON or Go struct for now) and allow environment-based overrides later.
   - Update chat rendering to pull colors from the theme interface.

3. **Centralize commands & key bindings**:
   - Extract key handling from chat model into a `commands` package (e.g., Ctrl+C semantics, leader keys if needed).
   - Document defaults in the reference architecture so new components can register commands uniformly.

4. **Prompt & system prompt structure**:
   - Model prompts as data (text + metadata) in `internal/app`; let both CLI and UI reuse converters (e.g., to `lm.ChatMessage`).
   - Keep system prompt resolution in one place (chaining defaults, env overrides, custom files).

5. **Plan for persistent state**:
   - If we store preferences later (e.g., `SAI_NO_STREAM` toggled interactively), follow Opencode’s `State` approach: per-user config folder, TOML/JSON file, load/save helpers.

6. **Adopt background workers**:
   - Continue to stream completions through channels, but consider a higher-level `event` package if we grow additional streams (notifications, context refreshes).

7. **Documentation & onboarding**:
   - Keep this reference file up to date as we implement changes.
   - Add README sections summarizing the internal package purpose (mirroring Opencode’s clarity).

By aligning the structure with Opencode’s proven patterns—while trimming what we do not need—we’ll gain flexibility for future UI expansion (modes, dialogs, theming) without sacrificing the simplicity of our current chat-focused CLI.
