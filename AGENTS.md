# Repository Guidelines

sai v2 is a Dart workspace: `packages/sai_core` (pure Dart), `apps/sai_app`
(Flutter macOS), `apps/sai_tui` (nocterm terminal client). The README has
the layout and the toolchain; this file has the rules.

## Feedback loop

- Tests first: write or update the test, watch it fail, make the change,
  re-run until green. Unit and provider tests in `packages/sai_core/test`
  (`dart test`), widget tests in `apps/sai_app/test` (`flutter test`),
  `testNocterm` tests in `apps/sai_tui/test` (`dart test`).
- Resolve once from the root with `dart pub get` (the Flutter SDK's
  `dart`, which knows where Flutter lives; `flutter pub get` does the same).
- Before pushing, run what CI runs — the "Verify" block in the README.
  `dart format` and `dart analyze --fatal-infos` gate every PR.
- Use the Context7 MCP for upstream docs (`riverpod`, `flutter`,
  `nocterm`) before changing state management or UI code, and cite what
  you relied on in the PR.

## Manual smoke

- A user-facing change gets a live pass on top of the tests, in a scratch
  env — never the real data dirs:
  `SAI_ARCHIVE_ROOT=<dir>/archive SAI_SETTINGS_FILE=<dir>/settings.json`.
  Seed settings with the TUI CLI (`dart run apps/sai_tui/bin/sai_tui.dart
  provider add …`) *before* launching the app: it reads the file once.
- Drive the app yourself; do not hand the clicks to a person.
  `tool/smoke/drive.sh launch <dir>` starts the debug bundle with that env
  (`open` drops env vars), `shot` captures the sai window, `click x y`
  posts a real mouse click at window-relative points (System Events'
  `click at` never reaches Flutter), `quit` closes it. Re-read the window
  frame before clicking and never click into another app.
- Evidence is the archive and the settings file after the pass plus a
  screenshot per step; put the results, not the claim, in the PR. A fake
  provider with a dummy loopback `endpoint` gets the dialog's `Test`
  button without dialling anything.
- Nothing in a smoke touches the login Keychain unless the ticket is
  about keys — and then say so before launching.
- The TUI is driven the same way, through a pseudo-terminal:
  `tool/smoke/tui.py <dir> <steps.json>` sends keys, waits for screen
  text and saves screen snapshots (no tmux needed). A real terminal
  delivers each key twice to nocterm and repaints cell by cell; the
  driver matches text with whitespace stripped.
- Two app quirks worth knowing: the first click after a launch or a
  burst of typing is often swallowed — click again and verify by the
  evidence, not by the click; synthetic ⌘-chords from System Events do
  not reach Flutter, so drive menu commands through the menu item
  (`click menu item "Enable Reasoning" of menu "View" …`).

## Boundaries

- `sai_core` never imports Flutter or `dart:ui`, and never a client. Its
  own test suite fails if it does. If something needs Flutter, it belongs in `apps/sai_app`.
- Clients depend on `sai_core` only; they never depend on each other.
- State lives in riverpod providers in `sai_core`; clients render them
  (`flutter_riverpod` in the app, `nocterm_riverpod` in the TUI). View
  logic that both clients need goes into the core, not into a client.
- Secrets go only through `SecretStore` in `sai_core` (the Keychain via
  `Security.framework`, ADR 0008): never `settings.json`, never the
  archive, never a log line, never an exception message, never the
  `security` command. Tests use `InMemorySecretStore` or a throwaway
  keychain file; nothing under `test/` touches the login keychain.
- Outbound HTTP goes only through `OpenAiCompatibleProvider`'s transport
  in `sai_core` (ADR 0009): no redirects, no proxy, no certificate
  bypass, plaintext only to localhost, fixed failure text naming an
  origin. Tests talk to a loopback stub, never the network.
- Task data reaches a provider only through `LlmRecorder`, which applies
  the privacy policy (ADR 0010): a caller puts the list in
  `LlmRequest.taskContext`, never in a message of its own, so a cloud
  provider can be denied it while the switch is off.
- A request is built by `assembleContext` and nowhere else (ADR 0011):
  profile, memory, lists and conversation in one deterministic, hashed
  shape. A client sends what it is given; it never assembles a prompt.
- `spikes/` are frozen evidence behind a decision. They stay out of the
  workspace and nothing imports them.
- The archive (`sai_core`'s event log) is append-only: no API updates or
  deletes a stored event, and nothing ever rewrites a line — corrections
  are new events. The format contract is `docs/archive/event-log-v0.md`;
  changing it means changing the spec, the ADR trail and the tests
  together.
- Technical decisions with consequences go to `docs/decisions/` as ADRs
  (see `0001-…`). Decisions made on the assistant's behalf are a separate
  log (#14).

## Style

- `dart format` output is canonical. Lints: `package:lints/recommended`
  in Dart packages, `package:flutter_lints/flutter` in the app.
- No code generation in the workspace yet (no `build_runner`,
  no `riverpod_generator`); revisit when a package earns it.
- Keep secrets, device identifiers, and machine-specific paths out of the
  tree.
- There is no v2 release process yet (#42). Pushing a `v*` tag does
  nothing; versions are bumped by hand (`saiVersion` and the pubspecs).

## Commits and pull requests

- Imperative, scoped subjects: `core: …`, `app: …`, `tui: …`, `ci: …`,
  `docs: …`, `chore: …`, `spike: …`. Body says what changed, not how it
  was found.
- Commits carry no tool-generated attribution or trailers. The patterns
  live in `.githooks/attribution-patterns`; `commit-msg` strips them,
  `pre-push` refuses them, and the CI `attribution` job refuses a PR that
  still carries one. Enable the hooks with
  `git config core.hooksPath .githooks`.
- Pull requests summarise the behaviour delivered, link the issue
  (`Closes #N`), and list the verification that was actually run. Include
  a clip or screenshot for UI changes, app or terminal.
