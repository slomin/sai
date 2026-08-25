# 8. Secrets live in the file keychain, through Security.framework

Date: 2026-08-24 · Status: accepted · Issue: #29 · Schema: [settings-v0](../settings/settings-v0.md)

## Context

Provider API keys have to be somewhere both clients can read them: the
Flutter app bundle and the `dart compile exe` terminal binary, built and
versioned independently. ADR [0006](0006-settings-live-in-a-file-beside-the-archive.md)
ruled the settings file out for anything secret, and the archive is a
life-long record that must never hold one.

Four places were considered: environment variables, the settings file
with permissions, the data-protection keychain, and the file-based
keychain — the last one either through the `security` command or
through `Security.framework` directly.

## Decision

Secrets go to the **file-based macOS Keychain** (the login keychain by
default), written and read **through `Security.framework` from
`sai_core`** over `dart:ffi` (`packages/sai_core/lib/src/secrets/`).
One implementation serves both clients.

- **One generic-password item per credential**: `service` is
  `me.slominski.sai`, `account` is the name the settings file carries
  (`provider:<id>`). The file names the account, never the value.
- **Update in place.** A write is `SecItemUpdate`, and only an absent
  item is `SecItemAdd`ed. Never delete-and-recreate: the item's access
  control list and partition list belong to the item, and recreating
  it resets them.
- **Never the `security` command.** An item written by
  `/usr/bin/security` trusts that tool, so any process that runs
  `security` reads the item silently, with no prompt. That is the
  documented weakness of the way some coding agents store their own
  credentials, and the reason the FFI path is not optional.
- **One stable signing identity for both binaries.** The item's ACL
  binds to the code-signing designated requirement of the app that
  created it. An ad-hoc signature (`CODE_SIGN_IDENTITY = -`, the
  default) changes on every build, so every rebuild re-prompts. A
  self-signed "Code Signing" certificate from Keychain Access, applied
  through the gitignored `macos/Runner/Configs/Local.xcconfig` and
  `tool/sign-tui.sh`, keeps the identity across builds in development;
  #42 signs releases with Developer ID. No identity name is in the tree.
- **Every test uses a throwaway keychain** created with
  `SecKeychainCreate` under a temp directory; nothing under `test/`
  reaches the login keychain, and nothing prompts. Off macOS the
  riverpod layer falls back to an in-memory store.
- **Failure text never carries a value.** The secret store's exceptions
  carry an `OSStatus` and a fixed message; the settings reader refuses
  a file that holds anything key-shaped and names the key, not the
  value; the recorder writes an exception's type, not its text.
  `test/no_secrets_test.dart` checks all of it from the outside.

Why not the alternatives:

- *Environment variables*: visible to every child process and every
  coding agent that runs a shell as the user (#56); not a store, and
  not readable by an app launched from the Dock.
- *The settings file*: a plain file with `0600` still ends up in
  backups, in `grep` output and in the repository one careless copy
  later. ADR 0006 already forbade it.
- *The data-protection keychain*: the right answer for a sandboxed,
  provisioned app, but it needs an Apple provisioning profile (TN3137)
  and is unreachable from a bare command-line binary. The TUI is a
  bare binary.
- *`security` CLI*: see above — it works, and it removes the prompt for
  everyone.

## What this defends, honestly

This defends the repository, the settings file, backups and the disk:
a key is in none of them, and a same-user process that is not sai gets
a prompt instead of a silent read. It is **not** a boundary against
code running as the user. The app runs without the App Sandbox (ADR
[0001](0001-the-macos-app-runs-without-the-app-sandbox.md)); a process
that can build and run a binary as the user can present itself to the
user for approval, or read the item after one careless "Always Allow".
#56 keeps real keys out of coding agents' reach by never giving them
one. The damage cap for a key that does leak is the provider's: scoped
keys, spend limits, rotation.

## Consequences

- The settings file grows a `providers` list (schema in
  `docs/settings/settings-v0.md`); `credential` there is an account
  name, and a secret-looking key or value makes the file unreadable
  rather than readable.
- Keys are entered from the terminal (`sai_tui secret set <id>`, hidden
  prompt) or the app (`sai › Providers…`, masked field). Removing
  a provider does not remove its key; `secret clear` does.
- `SecKeychainCreate`, `kSecUseKeychain` and `kSecMatchSearchList` are
  deprecated but exported on macOS 26; if they go, the tests move to a
  unique `service` in the login keychain with teardown deletion.
- Developers who skip the stable identity get a Keychain prompt on the
  first read after each rebuild. It is a prompt, not a failure.
