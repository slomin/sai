# 20. Functional text sets in the system face

Date: 2026-08-30 · Status: accepted · Issue: #99 · Builds on: [0018](0018-the-assistant-renders-markdown-with-sai-widgets.md)

## Context

The Sai visual system (`references/gui_design_v1_0/`) sets everything
in two families: Space Grotesk, a display face, and JetBrains Mono for
metadata and code. The first hour with the packaged app (#85) found
Space Grotesk awkward wherever text is read rather than looked at —
task titles, body copy, the chat, inputs, controls — and #99 asks for
the native macOS system sans in those roles. The system face cannot
be bundled: it is Apple's, licensed with the platform, and the
repository is public.

## Decision

- **Three faces, by role.** Functional text sets in the system sans;
  Space Grotesk stays for the brand and display roles — a pane's
  headline, an empty state's, the wordmark; JetBrains Mono stays for
  metadata and code. `SaiFonts` names the three, and `sans()`,
  `display()` and `mono()` in `sai_theme.dart` are the only places a
  family is chosen. The app is a Mac app, so the choice is
  the Mac's face and nothing else.
- **The system face is named, not shipped.** The theme sets
  `fontFamily: 'CupertinoSystemText'` — the family Flutter's own
  Cupertino text theme names, which the engine maps to the platform's
  system text font on Apple platforms. Nothing under `fonts/` changes.
  Functional styles carry no `FontVariation` axis any more; the
  display helper keeps setting Space Grotesk's.
- **Tests read the face from the OS.** `flutter test` draws an unloaded
  family with its block test font, which would turn every golden into
  boxes. The test config therefore loads
  `/System/Library/Fonts/SFNS.ttf` under the theme's family name
  (macOS only), so a golden shows the real glyphs and is reviewed as
  one. The pixels are then those of one macOS release: the CI app job
  runs on the runner image of the macOS the goldens were recorded on,
  and a macOS update that reshapes SF is a deliberate re-record, one
  file at a time, never a tolerance.

## Consequences

- The reference's specimen no longer matches the app one to one; the
  departure is this ADR, and the display roles keep the reference's
  voice.
- `ci.yml` pins the app job's runner (`macos-26` at this writing);
  bumping it is a `ci:` change made together with the goldens.
- A test machine on another macOS may see golden diffs of a few pixels
  in the system face; the goldens are recorded on the pinned release.
