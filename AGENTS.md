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
  (`open` drops env vars) — the dev flavor's `Debug-dev/sai-dev.app`
  unless `SAI_APP_BIN` names another; the window is found by the
  bundle's display name (`sai` or `sai dev`), so stable and dev can run
  through one smoke, each with its own scratch env — `shot` captures
  that window, `click x y`
  posts a real mouse click at window-relative points (System Events'
  `click at` never reaches Flutter), `record <secs> <file.mov>` clips
  the window's screen rect for a PR, `quit` closes it. Re-read the window
  frame before clicking and never click into another app.
- Evidence is the archive and the settings file after the pass plus a
  screenshot per step; put the results, not the claim, in the PR. A fake
  provider with a dummy loopback `endpoint` gets the dialog's `Test`
  button without dialling anything.
- The built-in `fake` streams at once; `SAI_FAKE_DELTA_MS=60` in the
  app's environment makes it pause before each delta, so a smoke can
  see the waiting state and the stream (#99).
- Nothing in a smoke touches the login Keychain unless the ticket is
  about keys — and then say so before launching. An agent's smoke is
  keyless (the `fake` provider, `lan.py`); a smoke against a cloud
  account is a person's job, `docs/smoke/cloud.md`.
- The TUI is driven the same way, through a pseudo-terminal:
  `tool/smoke/tui.py <dir> <steps.json>` sends keys, waits for screen
  text and saves screen snapshots (no tmux needed). Keys are not
  doubled in a real pty (one `^U` is one undo, measured in #41) — but a
  string and its Enter written in one chunk parse differently, so the
  driver writes one key per write; the screen repaints cell by cell,
  so the driver matches text with whitespace stripped. The first key
  after launch is swallowed: send a Tab and an Esc before typing.
- The LAN inference box (#23, the built-in `lan` provider) has its own
  contract check, `uv run tool/smoke/lan.py [--full]`: health, models,
  props, streaming, the thinking switch, vision and a needle buried in a
  long prompt (`--full` puts it near the 262k limit and holds the box's
  single slot for minutes — run it last). Python here runs through `uv`.
- What looked like "the first click gets swallowed" was two things
  (#40): the window not being where the coordinates assumed (a moved or
  resized window; a centred dialog moves with it) and a screenshot's
  shadow margin being taller below than above, which put every hand-
  converted y about 16 pt high. So: take shots with `drive.sh shot`
  (shadowless, 1:1 with the frame) and click with `drive.sh clickpx
  <shot> <px> <py>`, which converts for you and refuses when the window
  moved since the shot; never convert pixels by hand. Flutter's view does
  not take the first click on a non-key window, so `drive.sh` activates
  the app and waits for the window to be main before every click. Native
  menu key equivalents (⌘1–⌘7, ⌘K, ⌘J, ⌘,) do reach the app through
  System Events `keystroke`; chords bound only in-app do not — drive
  those through the menu item (`click menu item … of menu "View" …`).
  Bare keys — the arrows, Return, Escape — go through `drive.sh key
  <name|code> [name]`, which activates the window first.

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
  `security` command — with one exception, `tool/release.sh sign`,
  which may run exactly `security find-identity -v -p codesigning`
  against the dedicated signing keychain, keep the output out of every
  log and use only the one public identity it lists; it never inspects
  or mutates generic-password items, and no script unlocks a keychain
  or changes a search list, ACL or partition list
  (`no_spawn_test` pins this). The dev flavor opens no Keychain at all
  (#95). Tests use `InMemorySecretStore` or a throwaway keychain file;
  nothing under `test/` touches the login keychain.
- Agents never hold a credential (#56). An agent never receives or asks
  for a real key, never reads a vendor's credential store or Keychain
  item, never runs `security find-generic-password`, and never spawns
  `claude` or `codex app-server` against a real home — provider tests
  go through the fake process runner (`test/no_spawn_test.dart` lists the only
  files that may start a process). Agents run keyless smokes only; a
  person runs the cloud ones (`docs/smoke/cloud.md`). Enforced, not
  just written: `.claude/settings.json` turns on the Bash sandbox with
  those variables unset and those homes denied, and strips the same
  names from every subprocess; `.gitleaks.toml` fails a push or a PR
  that carries a key. Four command shapes run outside the sandbox:
  `dart *` and `flutter *` — the toolchain does not work under
  Seatbelt (a Dart `HttpClient` fails `CERTIFICATE_VERIFY_FAILED`, so
  every implicit `pub` resolution fails, and `flutter test` cannot
  bind its loopback socket) — `gh *` (Go TLS fails the same way,
  `x509: OSStatus -26276`) and the fixed-purpose
  `tool/smoke/drive.sh *` (Apple Events for the app smoke). That is
  the honest residual: code an agent writes and runs through `dart`
  is not file-isolated, which is why the vendor homes hold no
  plaintext of ours (ADR 0013: keyring `CODEX_HOME`, Claude Code's
  Keychain item) and why `no_spawn_test` and the scanner exist. The
  exclusion is judged on the whole command line, so run the toolchain
  as a bare line (`dart test`, after a separate `cd`) — `cd x && dart
  test` is sandboxed as a whole and fails. Everything else — `gh`,
  `git`, `uv`, `curl` — runs sandboxed and may write only under the
  repository, `$TMPDIR` and the listed caches; nothing sandboxed can
  read `~/.claude` — including this session's own saved tool output,
  so keep test output small (`--reporter=failures-only`). The
  `/sandbox` panel writes
  that same local file and can switch the sandbox off for you; the
  deny lists still hold. One consequence: the sandbox refuses to
  rewrite `.claude/settings.json`, so a sandboxed `git rebase` or
  `checkout` that would touch it fails part-way — edit that file with
  the Edit tool and leave history rewrites to a terminal.
- Outbound HTTP goes only through `OpenAiCompatibleProvider`'s transport
  in `sai_core` (ADR 0009): no redirects, no proxy, no certificate
  bypass, plaintext only to this machine or the LAN (ADR 0012), fixed
  failure text naming an origin. Tests talk to a loopback stub, never the network.
- Task data reaches a provider only through `LlmRecorder`, which applies
  the privacy policy (ADR 0010): a caller puts the list in
  `LlmRequest.taskContext`, never in a message of its own, so a cloud
  provider can be denied it while the switch is off.
- A request is built by `assembleContext` and nowhere else (ADR 0011):
  profile, memory, lists and conversation in one deterministic, hashed
  shape. A client sends what it is given; it never assembles a prompt.
- The Things 3 database is private data and this repository is public
  (#18). Nothing read from it — a row, a title, a copy of the file, a
  dry-run listing — goes into the tree, a test, a PR, an issue or a
  screenshot; evidence from a real import is counts only. Tests build
  their Things databases with `package:sai_core/things_testing.dart`,
  and `.gitignore` refuses `*.sqlite*` and `*.thingsdatabase/`. The
  importer reads a private copy under the system temp dir and never
  opens the file in the Things container.
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
- Releases are built and published by hand with `tool/release.sh`
  (`docs/release/README.md`, ADR 0017); CI has no release job and a
  pushed `v*` tag does nothing. Building and signing are two phases
  (#95): `prepare stable` runs every toolchain with no identity in
  reach; `sign` is a person's step — it reads the dedicated signing
  keychain and macOS asks at the dialog — an agent never runs it, never
  creates, unlocks or touches that keychain, and never holds an
  identity name. `tool/release.sh local-install dev` builds and installs
  the dev copy on this Mac (#87), signed low or ad-hoc, holding no
  credentials — it writes under `~/Applications` and `~/.local`, which
  the sandbox denies — an agent runs that one command with the sandbox
  switched off (`/sandbox`) and says so first; `local-install stable`
  installs a release a person has signed. Two flavors exist and no third
  (ADR 0019): `stable` is the daily copy, `dev` the isolated one beside
  it; a flavorless `flutter run`/`build` is dev, and publishing is
  stable-only. `tool/test/install_local_test.sh` covers the installer,
  both flavors and their isolation, with fixture releases against
  temporary roots; `tool/test/release_sign_test.sh` covers the sign
  phase with a fake `security`/`codesign`. Bump `saiVersion` and the
  three pubspecs together before a release; tests keep them equal.

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
