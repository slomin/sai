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

## Amendment (2026-08-26, #18)

The importer landed as a TUI command only (`sai_tui things import`); the
app never reads the Things container, so the reason above no longer
applies. The app stays unsandboxed anyway, as a settled decision rather
than a deferral: the sandbox is a build-time entitlement, not something
one operation can opt into, and turning it on would move the app's data
into its container and break the one archive the app and the terminal
client share (ADR 0006). For a hand-distributed local app (#42) that
trade is not worth it. Revisit only if App Store distribution becomes a
goal.

## Amendment (2026-08-27, #40)

The app imports from Things after all: first-run setup and Settings ›
Archive run the same core importer the TUI command runs, so the app
reads the group container again — under the importer's discipline
(`things_db.dart`): a private copy under the system temp directory,
never the file in the container, and nothing of a title in state, a
log or a report. The original reason for staying out of the sandbox
holds once more, and the 2026-08-26 amendment's "the app never reads
the Things container" no longer does. Reading the container from the
app bundle may need Full Disk Access; the import's permission failure
names that step.
