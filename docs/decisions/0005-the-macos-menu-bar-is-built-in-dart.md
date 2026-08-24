# 5. The macOS menu bar is built in Dart

Date: 2026-08-24 · Status: accepted · Issue: #37

## Context

The app shell (#37) needs a native menu bar with the standard items and
a home for the app's own commands and shortcuts — one that keeps
growing as list views (#38), chat (#39) and settings (#40) land. Flutter
offers two routes: edit the Cocoa nib the macOS runner ships with
(`macos/Runner/Base.lproj/MainMenu.xib`) and wire items to Dart over
platform channels, or describe the menu in Dart with `PlatformMenuBar`
and let the embedder install it.

## Decision

The menu bar is **described in Dart** (`apps/sai_app/lib/menus.dart`)
with `PlatformMenuBar`. The standard items — About, Services, Hide,
Quit, Start/Stop Speaking, Enter Full Screen, Minimize, Zoom, Bring All
to Front — are `PlatformProvidedMenuItem`s, the platform's own. Every
other item calls one of the app's commands (`AppCommands`), the same
handlers the key bindings and buttons use, so a chord bound in both the
menu and the widget tree fires exactly once: on macOS the menu's key
equivalent takes it before the Flutter view sees the key; under
`flutter test`, where there is no native menu, the in-app binding takes
it.

**`MainMenu.xib` stays exactly as shipped.** The embedder reads the
nib's menus once at startup and copies the platform-provided items out
of it on request; trimming the nib would silently break About, Services,
Hide and the rest.

## Alternatives

- **Extend the nib** — rejected: every app command needs a Swift
  handler and a channel round-trip, the menu's state (undo availability,
  chat visibility) has to be mirrored across the boundary, and none of
  it is reachable from `flutter test`.
- **A third-party menu package** — rejected: the built-in API covers the
  need and adds no dependency to vet.

## Consequences

- Replacing the menu bar drops the nib's Edit-menu text items (Cut,
  Copy, Paste, Select All, Find, Spelling) from the bar. The key chords
  keep working — Flutter's `DefaultTextEditingShortcuts` handles them —
  so only the menu entries are gone. Recreating them as items is a
  known, contained job for when the Edit menu earns it.
- Cmd+Z is always the app's undo, never the text field's. With an empty
  undo stack the Edit > Undo item is disabled, so the chord reaches the
  in-app binding, which swallows it: left to fall through, Flutter's own
  text undo would bring the last captured line back into the field. This
  continues the tradeoff #19 documented.
- Platform menu items carry no checked state, so the Go menu cannot
  mark the selected list; the sidebar shows it.
- Menu accelerators never fire in `flutter_test`; tests exercise the
  items through a stand-in `PlatformMenuDelegate` that records the menu
  the app would have sent, and drive the chords through the in-app
  bindings.
- Every rebuild of the chrome re-sends the whole menu. The chrome sits
  above the shell and watches only what the menu shows, so that is
  rare.
