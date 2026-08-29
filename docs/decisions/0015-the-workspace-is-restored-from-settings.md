# 15. The workspace is restored from settings, the window from AppKit

Date: 2026-08-27 · Status: accepted · Issue: #76 · Builds on: [0006](0006-settings-live-in-a-file-beside-the-archive.md)

## Context

#76 finishes the keyboard-first workflow and asks the app to come back
where it was left: the selected list or project, the task open in the
inspector, which areas are folded in the sidebar, whether the assistant
pane is shown, and the window's size and position. None of that is a
record — nothing sai saw or did — and none of it may hold task text or a
secret. Until now the only persisted preferences were the provider
settings in `settings.json` (ADR 0006), and the app remembered nothing
between launches.

Four places were considered: the settings file, a second app-only
preference file, the archive as events, and the platform's own defaults.

## Decision

**UI state lives in `settings.json`, as one optional `workspace`
object** carrying identifiers and booleans only: the selected section as
a `sectionKey` string, the selected task id, the folded area ids, and
the assistant switch (`docs/settings/settings-v0.md`). It is written by
the app a little after the workspace moves — one write for a run of
clicks, flushed when the app is asked to quit — and read once at launch.

The object is **read leniently**: a `workspace` that is not an object,
or a member of the wrong type, decodes as the default and is dropped on
the next write; it never quarantines the file. The provider settings are
worth a quarantine; a stale view is not. Every restored id is then
**checked against the projection** before use, in core
(`restoreWorkspace`): a list or the Trash is always valid; an area,
project or tag only while it exists and is not deleted (archived stays
browsable); anything else falls back to Today and drops the task; the
task is kept only while the chosen section actually shows it, so
selecting section then task never has the selection cleared by the
view's own rules.

**The window frame lives in AppKit's frame autosave**, not in the file:
`MainFlutterWindow` names its frame (`sai.main`) and the platform keeps
it in the app's defaults, restores it, and clamps it to the screens that
exist; a minimum size keeps the sidebar on screen. No Dart, no plugin,
no method channel, and macOS's own rules for a display that is gone.

## Consequences

- `settings.json` gains its first non-provider key. `version` stays 0:
  the key is optional, omitted while empty, and an older sai carries it
  as an unknown key it does not touch.
- Two clients writing the file at once are last-write-wins on the
  workspace, as ADR 0006 already accepts for every preference; the TUI
  writes no `workspace` of its own.
- A scratch run that sets `SAI_SETTINGS_FILE` gets a scratch workspace
  but shares the real window frame: the frame is keyed by bundle id in
  `NSUserDefaults`, outside the file. A smoke that resizes the window
  moves the real one. Since ADR 0019 the dev flavor has its own bundle
  id and its own frame name (`sai-dev.main`), so a smoke on a dev build
  never moves the daily copy's window — only a scratch run of the same
  flavor shares its frame.
- The debounced write can lose the very last move if the process is
  killed inside the window; ⌘Q flushes it through the app's exit
  request. Accepted: the loss is one selection.
- The restore is app-side, above the shell, rather than inside the core
  notifiers' `build`: a bare provider container — every core test — must
  not read a settings file it did not override.

## Alternatives rejected

- **A second, app-only preference file.** Another path to resolve,
  override in every harness, and document, for four values that fit the
  existing file's rules.
- **Archive events.** The workspace is not something sai saw or did; a
  `workspace.select` line per click would be noise in the record, and
  every open would replay the log to find the last one.
- **The window frame in the file.** A resize storm would need its own
  debounce and the app would have to re-implement the clamping AppKit
  does for free; the one cost — a scratch run sharing the frame — is
  recorded above.
