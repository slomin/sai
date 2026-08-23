# Decision: nocterm for the sai terminal client

Issue: [#10](https://github.com/slomin/sai/issues/10) · nocterm 0.9.0 ·
Dart 3.13.1 · macOS arm64 · 2026-08-23 · reviewed in
[#44](https://github.com/slomin/sai/pull/44)

## Notes for the real client (not fixed here, this is a spike)

- A dropped provider stream must surface on screen; the spike's
  `onError` appends a marker and clears the busy state, the real client
  needs a proper error message and retry.
- Sending while a reply streams is refused with a `busy` notice; the
  real client should queue or interrupt instead.
- `ensureIndexVisible` runs only on selection change; a resize can leave
  the selected row off-screen until the next `j`/`k`. Re-run it after
  layout changes.

## Recommendation: go

Build `apps/sai_tui` on nocterm, kept thin over `sai_core`. Pin `^0.9.0`
in #9. Re-evaluate only if a release breaks the API surface used here
(`StatefulComponent`, `Focusable`, `ListView.builder`, `TextField`,
`testNocterm`).

## Criteria

| Criterion | Result | Evidence |
|---|---|---|
| List + streaming chat pane at once, no flicker | Pass on capture; visual check pending | The renderer paints cell diffs, not full frames: `tool/pty_probe.py` drives a whole session (startup, 68 streamed tokens, UTF-8 input, focus changes) and counts 2 cursor-home sequences and ~7.7 KB written during the stream. Every token rebuilds the whole tree (`setState` at the root) and only the changed cells reach the terminal. That is the mechanism that prevents flicker; what it *looks* like in a real terminal, plus resize and bracketed paste, is the human check below. |
| UTF-8 paste and multi-line entry | Pass | `TextField(maxLines: 4)` accepts `żółć 🚀`, `Ctrl+J` inserts a newline (Shift/Alt/Ctrl+Enter also work where the terminal speaks the kitty keyboard protocol), pasted text keeps its newlines in multi-line fields (`text_field.dart:859-866`). Covered by `test/spike_test.dart` "UTF-8 and multi-line". |
| Hot reload with `dart --enable-vm-service` | Pass | Save → `[HotReload] Change detected` → `reassembled successfully` in ~90 ms; a changed `Text` in `build()` is on screen ~3 s after save. |
| `testNocterm` in CI | Pass | 6 tests: layout, vim/arrow navigation incl. scroll-to-selection, token-by-token streaming, UTF-8 multi-line input, draft/busy handling, modified-`q` ignored. Run by `.github/workflows/spike-nocterm.yml`. |
| Go/no-go with fallback cost | This document | |

## Rough edges found (none blocking)

1. **`pumpAndSettle` never settles** (`nocterm_test_binding.dart:85-103`):
   it treats the frame it just pumped as "a change", so it always hits
   `maxIterations`. Workaround in `test/spike_test.dart`: `pumpFor` /
   `pumpUntilText` helpers driving `pump(duration)`. Worth an upstream
   issue.
2. **`TextField` placeholder does not update on hot reload**; other
   `build()` changes do. Likely cached inside the field's state. Cosmetic.
3. **`print` is invisible**: stdout is redirected to a WebSocket log
   server (`~/.nocterm/<hash>/log_port.<pid>`, path `/logs`). Use
   `nocterm_cli` or a client; the spike README shows the port file.
4. **Timing-sensitive tests**: the virtual terminal uses real timers, so
   tests that assert "partial output at t=25 ms" flake under load. Poll
   for state instead (done here).
5. **No `Platform.executableArguments` without `--enable-vm-service`**
   means hot reload silently stays off under plain `dart run`; the log
   says so, but only in the hidden log.
6. **`shutdownApp()` throws under `NoctermTester`** — it reads
   `TerminalBinding.instance`, which the test binding never sets. Quit
   paths are untestable as written; the "modified q" test works only
   because it asserts the call is *not* reached. Abstract "quit" behind
   an injectable callback in the real client.
7. **`AutoScrollController` takes a different path under the tester**:
   it tries `TerminalBinding.instance.addPostFrameCallback` and, when
   that throws (always, in tests), falls back to a synchronous
   `scrollToEnd()`. Auto-scroll timing is therefore not what tests
   measure; eyeball it.
8. **One always-focused root `Focusable` keeps the IME cursor on the
   `TextField`** even when another pane has focus (the binding finds the
   first focused `Focusable` and searches its whole subtree). Fixed here
   by giving each pane its own `Focusable`; key events bubble
   child-first, so the pane handler still sees what the field ignores.
9. Pre-1.0: 0.4 → 0.9 in six months. The API used here is the stable
   Flutter-shaped core; adapters (`nocterm_riverpod` 0.1.0) are younger.

## Fallback cost (thin Bubble Tea or Ratatui client over a local socket)

Not chosen. What it would cost:

- **A wire protocol that nothing else needs.** `sai_core` would have to
  expose its state and commands over a local socket (JSON-RPC or
  similar), with versioning, reconnection and auth-on-localhost, purely
  so a second language can draw it. With nocterm the TUI links
  `sai_core` directly, like the Flutter app does.
- **A second implementation of every view.** Key handling, list
  rendering, streaming text, input editing, tests — once in Dart for
  `sai_app`, again in Go or Rust. Two codebases drift; the "both clients
  show the same data" walking-skeleton criterion becomes a protocol
  conformance problem instead of a shared-state problem.
- **A second toolchain in CI and on the LAN box**, and a second place to
  keep secrets handling (Keychain) correct.
- **Lost: hot reload and `testNocterm`.** Bubble Tea's `teatest` and
  Ratatui's `TestBackend` are fine, but they test a different program
  than the one the Flutter app runs.

Rough size: the Go prototype in this repo (`internal/ui`, `internal/lm`)
is a fair proxy for the client half alone; the socket layer in
`sai_core` would be new work on top. The nocterm path costs a pre-1.0
dependency and the rough edges above.

## Still to eyeball (Jan)

The capture proves the mechanism, not the experience; resize and
bracketed paste are not exercised by any test. Run
`dart --enable-vm-service bin/spike.dart` in the terminal you actually
use, press `Enter` on a task to start a stream, resize the window
mid-stream, paste a multi-line block into the input, and save an edit to
`lib/spike_app.dart`. If any of that looks wrong, reopen #10.
