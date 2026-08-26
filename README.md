# sai

sai (Super AI) is a personal assistant that lives with one person's task
list. Version 2 starts as a Things-like todo app for macOS with an always-on
assistant beside it, built so that everything the assistant sees and does is
kept in an auditable archive. The roadmap lives on the
[project board](https://github.com/users/slomin/projects/12); the first
milestone is a walking skeleton (one task list, one model provider, events
logged, both clients showing the same data).

This repository is a Dart workspace:

| Path                 | What it is                                                                 |
| -------------------- | -------------------------------------------------------------------------- |
| `packages/sai_core`  | Pure Dart. Task model, archive, provider routing, and the shared riverpod layer. No Flutter. |
| `apps/sai_app`       | The Flutter macOS app. Depends on `sai_core`.                              |
| `apps/sai_tui`       | The terminal client on [nocterm](https://pub.dev/packages/nocterm). Depends on `sai_core`; built with `dart compile exe`. |
| `spikes/`            | Throwaway experiments that settled a decision. Not part of the workspace; each keeps its own `pubspec.lock`. |
| `docs/archive/`      | The archive format contract ([event log v0](docs/archive/event-log-v0.md)). |
| `docs/tasks/`        | The task model contract ([task model v0](docs/tasks/task-model-v0.md)).     |
| `docs/settings/`     | The settings file contract ([settings v0](docs/settings/settings-v0.md)).   |
| `tool/`              | Developer scripts (`sign-tui.sh`) and the smoke drivers (`smoke/`).         |
| `docs/decisions/`    | Technical ADRs.                                                            |

Both clients read the same providers from `sai_core`; nothing in `sai_core`
knows about either client.

## Toolchain

- Flutter 3.47.1 stable (Dart 3.13.1). CI pins the same version
  (`.github/workflows/ci.yml`), so match it locally.
- Xcode with the macOS platform, for `apps/sai_app`.

## Build and run

Resolve the whole workspace once from the repository root:

```sh
dart pub get   # or flutter pub get
```

Run the clients:

```sh
# macOS app
cd apps/sai_app && flutter run -d macos

# terminal client, from the root …
dart run apps/sai_tui/bin/sai_tui.dart
# … or from its own directory
cd apps/sai_tui && dart run
```

Both clients read and write the same archive. The terminal client
follows the app's writes as they land (it polls the archive head every
two seconds); the app picks up the terminal's when it opens.

In the terminal client, the top line captures (Enter saves, `@today`,
`!2026-09-01`), `↑`/`↓` move the cursor over the tasks below, `^D`
completes the selected one and `^U` undoes; the last two rows name the
active provider with its `local`/`cloud` tag and the keys. It ships as
one binary — `dart compile exe apps/sai_tui/bin/sai_tui.dart -o
build/sai_tui`, or signed via `tool/sign-tui.sh` (below). To try one against a scratch archive instead of the real one,
point `SAI_ARCHIVE_ROOT` at a throwaway directory, e.g.
`SAI_ARCHIVE_ROOT=/tmp/sai-demo/archive`. Non-secret settings live in
`settings.json` in the same data directory as the default archive;
`SAI_SETTINGS_FILE` moves them, and a scratch run sets both. Three
providers are built in and need no configuration: `lmstudio` (LM
Studio's server on this Mac, `http://127.0.0.1:1234/v1`, whatever model
it has loaded), `lan` (the LAN inference box, #23) and `fake` (answers
offline). A first run — no settings file yet — selects `lmstudio`;
`provider use lan|fake|none` changes that, and `{"version":0,"llm":"fake"}`
in the settings file is the offline choice.

## Providers and keys

Provider settings (endpoints, default models, the active provider) are
managed from the terminal client's subcommands and stored in
`settings.json`; API keys go to the macOS Keychain and are never written
to a file or the archive (ADR 0008, [settings v0](docs/settings/settings-v0.md)):

```sh
# a local llama-server or LM Studio, keyless
dart run apps/sai_tui/bin/sai_tui.dart provider add local --kind openai_compatible \
  --endpoint http://127.0.0.1:1234/v1 --model <model-id>
dart run apps/sai_tui/bin/sai_tui.dart provider use local
# a box with a key, over TLS
dart run apps/sai_tui/bin/sai_tui.dart provider add box --kind openai_compatible \
  --endpoint https://box.example:8443/v1 --model <model-id> --key
dart run apps/sai_tui/bin/sai_tui.dart secret set box     # hidden prompt
# the built-in LAN box, or LM Studio, with another model or address
dart run apps/sai_tui/bin/sai_tui.dart provider add lan --kind openai_compatible \
  --endpoint http://192.168.1.5:8080/v1 --model <model-id>
dart run apps/sai_tui/bin/sai_tui.dart provider list
```

Two kinds exist: `fake` (offline) and `openai_compatible` (any `/v1`
endpoint: `llama-server`, LM Studio, the LAN server); a configured
provider with a built-in's id replaces it. Plain
`http://` is accepted only on this machine or the LAN (loopback and
private addresses, `.local`-style and dotless names — ADR 0012);
anything else must be `https://` with a certificate this Mac trusts —
sai follows no redirects, uses no proxy and bypasses no certificate
(ADR 0009). A key entered for a plaintext LAN endpoint travels the LAN
in the clear. A key
is bound to the endpoint it was entered for: moving an endpoint to
another host, port or scheme means entering its key again. Adding an
existing id changes only the options given (`--no-key` drops the key
reference); `secret clear <id>` removes a key whether or not its
provider is still configured.

The app reads the same settings and keys: `sai › Providers…` lists every
provider, switches the active one in a click, refreshes an endpoint's
health, models and context window, runs a recorded streaming test (the
result and llama.cpp tokens/s land in the archive), and enters or
removes a key. `sai_tui help` lists every command.

Every provider is tagged `local` or `cloud`, and the tag is always on
the status line and in `provider list`. A cloud provider sees your task
list only while the switch "Allow cloud providers to see my tasks" is
on — off by default, in the Providers dialog or `sai_tui privacy
share-tasks on|off` (`sai_tui privacy` shows it). While it is off the
status line reads `· tasks withheld`, selecting a cloud provider says
so, and the assistant answers without the list; each cloud call is
preceded by a `policy.decision` line in the archive (ADR 0010). An
`openai_compatible` endpoint counts as `local` on this machine or the
LAN and `cloud` on any other host; `--privacy local|cloud` overrides
that when you know better (a tunnel, a reverse proxy). No cloud kind
exists yet: to try the policy, give the fake one a tag —
`provider add cloudy --kind fake --privacy cloud`.

For a local test, LM Studio's server (default port 1234) or
`llama-server -m <model.gguf> --port 8080` work as they are; give
`llama-server` a key with `--api-key-file`, never `--api-key` (argv is
visible to every process).

Keychain items trust the binary that created them by its code-signing
identity. Ad-hoc signed builds (the default) get a new identity on every
build and so a Keychain prompt after every rebuild. To avoid that in
development, make a self-signed identity once — Keychain Access →
Certificate Assistant → Create a Certificate, type *Code Signing*, name
it e.g. `sai-dev` — and point both builds at it, keeping the name out of
the tree:

```sh
# app: gitignored per-machine override, picked up by Debug and Release
echo 'CODE_SIGN_IDENTITY = sai-dev' > apps/sai_app/macos/Runner/Configs/Local.xcconfig
# terminal client: compile and sign in one step
SAI_CODESIGN_IDENTITY=sai-dev tool/sign-tui.sh build/sai_tui
```

Build a debug app bundle (what CI does): `cd apps/sai_app && flutter build
macos --debug` → `apps/sai_app/build/macos/Build/Products/Debug/sai.app`.

## Chat

Both clients carry the conversation (#34): the pane in the app (⌘J
shows and hides it; Enter sends, Esc or **Stop** ends an answer) and
the lower pane in the TUI (Tab moves between capture and chat; Enter
sends, Esc stops). The assistant sees Today and Upcoming as you see
them, rendered by one function in `sai_core` and carried apart from the
messages so the privacy policy can withhold them (ADR 0011, 0010); it
reads the list and cannot change it. Every turn is in the archive — the
user's `chat.message`, the call's `provider.*` lines with a
`context_hash` of exactly what the model saw, and the assistant's
`chat.message` naming the model that answered. With a cloud provider
and sharing off, the answer is marked `tasks withheld`. A model that
thinks before it answers (LM Studio's reasoning models do) is asked not
to unless the reasoning switch is on — in the Providers dialog, View ›
**Enable Reasoning** (⌘R), or `sai_tui reasoning on`; off is faster and
the default. On, the thinking streams too, is recorded on the response
line, and shows dimmed above the answer (`thinking…` while it waits).

## Importing from Things 3

`sai_tui things import --dry-run` shows what the archive would gain from
the Things 3 database on this Mac; without `--dry-run` it writes it, as
`system` events carrying each item's Things uuid, so a second run adds
only what changed. Things is never written to — the command reads a
private copy — and the report is counts only (`--db <main.sqlite>` or
`SAI_THINGS_DB` names another file). Repeating rules, reminders,
completed projects and the Trash are reported, not imported; the mapping
is in `docs/tasks/task-model-v0.md` § Imports.

## Verify

Same commands CI runs, from the repository root:

```sh
dart format --output=none --set-exit-if-changed packages apps/sai_tui apps/sai_app/lib apps/sai_app/test
dart analyze --fatal-infos packages apps
(cd packages/sai_core && dart test)
(cd apps/sai_tui && dart test)
(cd apps/sai_app && flutter test)
(cd apps/sai_app && flutter build macos --debug)
gitleaks git . --config .gitleaks.toml   # no secret in any commit
```

`sai_core` must stay free of Flutter: its tests fail if `lib/` imports
`package:flutter` or `dart:ui`, or if its pubspec declares a Flutter
dependency.

The event log under the archive root is verifiable without sai at all —
each line's id is the SHA-256 of its exact bytes (`shasum -a 256`); the
contract is [docs/archive/event-log-v0.md](docs/archive/event-log-v0.md).

## Git hooks

Commits here carry no tool-generated attribution and no secret. The
attribution patterns are in `.githooks/attribution-patterns`; `commit-msg`
strips matching lines, `pre-push` refuses to push commits that still have
them, and CI refuses a pull request that does. The same `pre-push` runs
[gitleaks](https://github.com/gitleaks/gitleaks) over the commits about
to leave the machine (rules in `.gitleaks.toml`), and the CI `secrets`
job scans the tree and the pull request; a provider key in a commit
fails both. Enable the hooks once per clone:

```sh
git config core.hooksPath .githooks
brew install gitleaks
```

## The Go prototype

sai v1 was a Go/Bubble Tea terminal chat client for llama.cpp. It is no
longer on `main`; it is kept as is at tag
[`go-final`](https://github.com/slomin/sai/tree/go-final) (sources, its own
README and `install.sh`) and branch
[`archive/go-bubbletea`](https://github.com/slomin/sai/tree/archive/go-bubbletea),
and its last binaries are the
[v0.1.0 release](https://github.com/slomin/sai/releases/tag/v0.1.0).
The install one-liner in that era's README and release notes fetched
`install.sh` from `main`, which no longer has it; the working URL is
`https://raw.githubusercontent.com/slomin/sai/go-final/install.sh`. What
v1 left on a machine and how to remove it is in
[`docs/decisions/0002`](docs/decisions/0002-retire-the-go-prototype.md).

## License

Mozilla Public License 2.0 — see [LICENSE](LICENSE).
