# 1. The macOS app runs without the App Sandbox

Date: 2026-08-23 · Status: accepted · Issue: #9

## Context

The Things 3 importer (#18) reads the Things SQLite database straight from
its group container under `~/Library/Group Containers/`. A sandboxed app
cannot open another app's container without a user-granted security-scoped
bookmark on every launch, and Flutter's file pickers do not give us one for
a directory the user never sees.

The app is distributed by hand (#42), not through the App Store, so the
sandbox is not required by any store policy.

## Decision

`com.apple.security.app-sandbox` is `false` in both
`apps/sai_app/macos/Runner/DebugProfile.entitlements` and
`apps/sai_app/macos/Runner/Release.entitlements`. The debug profile keeps
`allow-jit` and `network.server`, which Flutter's hot reload needs.

## Consequences

- The importer can read the Things container with plain file I/O.
- App Store distribution is off the table until this is revisited.
- Every file the app touches is protected only by ordinary POSIX
  permissions and TCC prompts (Desktop, Documents, etc.), not by the
  sandbox. Keep the archive under `~/Library/Application Support/sai/`
  so nothing else needs a TCC grant.
- Revisit when #18 is done: if the importer ends up running only from the
  TUI binary, the app could go back into the sandbox.
