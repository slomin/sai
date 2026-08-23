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

## Boundaries

- `sai_core` never imports Flutter or `dart:ui`, and never a client. Its
  own test suite fails if it does. If something needs Flutter, it belongs in `apps/sai_app`.
- Clients depend on `sai_core` only; they never depend on each other.
- State lives in riverpod providers in `sai_core`; clients render them
  (`flutter_riverpod` in the app, `nocterm_riverpod` in the TUI). View
  logic that both clients need goes into the core, not into a client.
- `spikes/` are frozen evidence behind a decision. They stay out of the
  workspace and nothing imports them.
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
