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
| `apps/sai_tui`       | The terminal client on [nocterm](https://pub.dev/packages/nocterm). Depends on `sai_core`; built with `dart build cli`. |
| `spikes/`            | Throwaway experiments that settled a decision. Not part of the workspace; each keeps its own `pubspec.lock`. |
| `docs/archive/`      | The archive format contract ([event log v0](docs/archive/event-log-v0.md)). |
| `docs/tasks/`        | The task model contract ([task model v0](docs/tasks/task-model-v0.md)).     |
| `docs/settings/`     | The settings file contract ([settings v0](docs/settings/settings-v0.md)).   |
| `docs/release/`      | Installing, upgrading and building a release ([README](docs/release/README.md)). |
| `tool/`              | Developer scripts (`release.sh`, `install-local.sh`, `verify-release.sh`, `build-tui.sh`, `app-icons.swift`) with their tests and smoke drivers. |
| `docs/decisions/`    | Technical ADRs.                                                            |

Both clients read the same providers from `sai_core`; nothing in `sai_core`
knows about either client.

## Toolchain

- Flutter 3.47.2 stable (Dart 3.13.2). CI pins the same version
  (`.github/workflows/ci.yml`), so match it locally.
- Xcode with the macOS platform, for `apps/sai_app`.

## Build and run

Resolve the whole workspace once from the repository root:

```sh
dart pub get   # or flutter pub get
```

Run the clients:

```sh
# macOS app — the dev flavor unless told otherwise
cd apps/sai_app && flutter run -d macos
cd apps/sai_app && flutter run -d macos --flavor stable

# terminal client, from the root …
dart run apps/sai_tui/bin/sai_tui.dart          # stable
dart run apps/sai_tui/bin/sai_tui-dev.dart      # dev
# … or from its own directory
cd apps/sai_tui && dart run
```

sai has two installed flavors and no third (ADR 0019): **stable** is
the daily-use copy — `sai.app`, `sai_tui`, `Application Support/sai`,
Keychain service `me.slominski.sai` — and **dev** the isolated
development copy beside it — `sai-dev.app`, `sai_tui-dev`,
`Application Support/sai-dev`, service `me.slominski.sai.dev`, a `DEV`
label in its header. The two share nothing and run at once. A
`flutter run` or `flutter build macos` that names no flavor is dev
(`default-flavor` in the app's pubspec), so nothing you build by
accident can pass for the daily copy; `--flavor stable` is deliberate.
The same is true in Xcode: the `stable` and `dev` schemes are the
flavors, and the plain `Runner` scheme builds dev.

The icons make the same distinction before a window opens: stable uses
the canonical near-white/ink/red Sai mark; dev keeps that mark and cuts
its upper-right ink corner into one large green field. Their curated
1024px masters live under `apps/sai_app/macos/Runner/IconSources/` and
`swift tool/app-icons.swift prepare` regenerates both macOS catalogs;
`check` refuses stale sizes or Flutter's retired placeholder.

Both clients of a flavor read and write the same archive. The terminal client
follows the app's writes as they land (it polls the archive head every
two seconds); the app picks up the terminal's when it opens.

In the terminal client, the top line captures (Enter saves, `@today`,
`!2026-09-01`), `↑`/`↓` move the cursor over the tasks below, `^D`
completes the selected one (a task finished today stays in its list
with a tick until midnight and `^D` reopens it — Settings › General,
or `sai_tui finished-tasks immediate`, drops it into the Logbook at
once) and `^U` undoes; the last two rows name the
active provider with its `local`/`cloud` tag and the keys. It ships as
a bundle, the binary beside the SQLite it bundles — `dart build cli -t
apps/sai_tui/bin/sai_tui.dart --root-package=sai_tui -o build/tui` puts
it at `build/tui/bundle/bin/sai_tui` (`dart compile exe` refuses the
build hook `package:sqlite3` needs; `bin/sai_tui-dev.dart` is the dev
entry point and lands as `sai_tui-dev`) — `tool/build-tui.sh
[output-dir] [stable|dev]` does the same and ad-hoc signs every Mach-O. To try one against a scratch archive instead of the real one,
point `SAI_ARCHIVE_ROOT` at a throwaway directory, e.g.
`SAI_ARCHIVE_ROOT=/tmp/sai-demo/archive`. Non-secret settings live in
`settings.json` in the same data directory as the default archive;
`SAI_SETTINGS_FILE` moves them, and a scratch run sets both. Four
providers are built in and need no configuration: `lmstudio` (LM
Studio's server on this Mac, `http://127.0.0.1:1234/v1`, whatever model
it has loaded), `lan` (the LAN inference box, #23), `fake` (answers
offline) and `openrouter` (the cloud broker, #24 — inactive until a
key is stored). A first run — no settings file yet — selects `lmstudio`;
`provider use lan|fake|none` changes that, and `{"version":0,"llm":"fake"}`
in the settings file is the offline choice. The app's first launch
(#40) asks once — start empty, or import from Things 3 after a
preview — and lands in the Inbox; the same import is in Settings ›
Archive later, and `setup: "done"` in the file is what ends the asking.

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

Three kinds exist: `fake` (offline), `openai_compatible` (any `/v1`
endpoint: `llama-server`, LM Studio, the LAN server) and `openrouter`
(ADR 0022: fixed to `https://openrouter.ai/api/v1`, always `cloud`,
always keyed — `secret set openrouter` configures the built-in and
files the key; on its recommended preset every request pins
`deepseek/deepseek-v4-flash-0731` to DeepInfra fp8 with no fallback,
denies data collection and requires zero retention, and `provider add
openrouter --model <owner/name>` chooses one exact model instead;
`--routing recommended` returns to the preset; `openrouter/auto`,
`~latest` aliases and `:nitro`/`:floor`/`:online` are refused; removing
the key in sai removes the Keychain item only, so revoke it at
openrouter.ai too — use a dedicated key with a spending cap); a
configured provider with a built-in's id replaces it. Plain
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

The app reads the same settings and keys: Settings › Providers (⌘,)
lists every provider, switches the active one in a click, refreshes an endpoint's
health, models and context window, runs a recorded streaming test (the
result and llama.cpp tokens/s land in the archive), and enters or
removes a key. `sai_tui help` lists every command.

Every provider is tagged `local` or `cloud`, and the tag is always on
the status line and in `provider list`. A cloud provider sees your task
list only while the switch "Allow cloud providers to see my tasks" is
on — off by default, in Settings › Providers or `sai_tui privacy
share-tasks on|off` (`sai_tui privacy` shows it) — and the switch
covers Today and Upcoming only: the complete catalog a local model
reads, and answers derived from it, never go to the cloud (#105). While it is off the
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

Development builds carry no stable signing authority and no persistent
credentials (#95, ADR 0017 and 0019): the dev flavor never opens a Keychain, a
credential-backed provider is *no credentials in dev*, and the fake and
the keyless local providers (LM Studio, the LAN box) are what a dev
copy talks to. Stable is signed in a separate phase from a dedicated
keychain that asks before its key is used ([docs/release](docs/release/README.md)).
An ad-hoc signed dev app gets a new code-directory hash on every build,
so macOS re-asks its permissions (Accessibility for the smoke driver,
say) after every rebuild. To keep them, make a self-signed identity
once — Keychain Access → Certificate Assistant → Create a Certificate,
type *Code Signing*, name it exactly `sai dev` — and
`tool/release.sh local-install dev` uses it when it is there, ad-hoc
otherwise; it signs nothing stable, and a certificate by that name that
cannot be used (a locked keychain, a denied key) stops the build rather
than falling back.

Build a debug app bundle (what CI does, for both flavors): `cd
apps/sai_app && flutter build macos --debug --flavor dev` →
`apps/sai_app/build/macos/Build/Products/Debug-dev/sai-dev.app`, and
`--flavor stable` → `Products/Debug-stable/sai.app`; with no flavor the
result is the dev one. A signed release of both clients is
`tool/release.sh` ([docs/release](docs/release/README.md)).

Your own copies — the one in the Dock and the one you develop against —
come from the same build, not from a release. With that flavor quit and
a clean tree:

```sh
tool/release.sh local-install dev              # build, verify, install the dev flavor
tool/release.sh prepare stable                 # build stable, unsigned and sealed
tool/release.sh sign                           # sign it from the dedicated keychain (macOS asks)
tool/release.sh local-install stable           # verify and install the signed release
tool/install-local.sh dist/sai-v<version>/release   # install what is already staged (dist/sai-dev-v… for dev)
tool/release.sh install references/releases/<name>  # roll back to a kept one
```

That puts `~/Applications/sai.app`, `~/.local/share/sai/bundle/` and
`~/.local/bin/sai_tui` in place — `sai-dev.app`, `~/.local/share/sai-dev/`
and `sai_tui-dev` for dev — checks signatures, checksums, the commit and
the flavor every artefact carries before replacing anything, and never
touches the archive, the settings file or the Keychain. Installing one
flavor while the other runs is fine; only that flavor's own copy has to
be quit. Upgrading is the same command again; `--dry-run` shows what
would happen. Publishing (`tool/release.sh publish`) is stable-only.
The full story — what is verified, where the kept copies live,
rollback — is in [docs/release](docs/release/README.md#the-dogfood-install).

The app's look is the Sai visual system (`references/gui_design_v1_0/`): the
tokens live in `apps/sai_app/lib/theme/`. Functional text — task titles,
body copy, the chat, inputs and controls — sets in the macOS system face,
named to Flutter as `CupertinoSystemText` and never bundled (ADR 0020);
the two families that ship as assets under `apps/sai_app/fonts/` beside
their SIL OFL licences are Space Grotesk, for the brand and display roles,
and JetBrains Mono, for metadata and code. Light appearance only for now.

## Chat

Both clients carry the conversation (#34): the pane in the app (⌘J
shows and hides it; Enter sends, Esc or **Stop** ends an answer) and
the lower pane in the TUI (Tab moves between capture and chat; Enter
sends, Esc stops). A local model sees your complete collection — every
task in Inbox, Anytime, Someday, projects, Logbook and Trash, with
notes, checklists, tags and placement — so it can answer questions
across all of it (#105); its budget follows the context window the
endpoint reports on probe, with a conservative default until the first
answer. Reading all that in can take a local machine minutes, so sai
warms the endpoint ahead of time: once the connection is ready (and
again after your tasks change), the catalog is sent in the background
with a one-token reply — the status line shows `warming up` with an
estimate — and your actual question then reuses the server's cached
prefix and starts fast. Warm-up calls are recorded in the archive like
any other. A cloud provider sees at most Today and Upcoming as you see
them, and never the catalog nor answers derived from it, whatever the
sharing switch says. Both shapes are rendered by one function in
`sai_core` and carried apart from the messages so the privacy policy
can withhold them (ADR 0011, 0010); the assistant reads the list and
cannot change it. Every turn is in the archive — the user's
`chat.message`, the call's `provider.*` lines with a `context_hash` of
exactly what the model saw, and the assistant's `chat.message` naming
the model that answered. With a cloud provider and sharing off, the
answer is marked `tasks withheld`. A model that
thinks before it answers (LM Studio's reasoning models do) is asked not
to unless the reasoning switch is on — in Settings › Providers, View ›
**Enable Reasoning** (⌘R), or `sai_tui reasoning on`; off is faster and
the default. On, the thinking streams too, is recorded on the response
line, and shows dimmed above the answer. While an answer is awaited the
app shows three dots breathing in turn (a still *Thinking* under Reduce
Motion; the TUI keeps its `…`), then the answer with a thin cursor as
it streams. The app's transcript selects like any text — drag with the
mouse, ⌘C copies the words exactly, a fence's copy control takes the
code alone.

The assistant can also propose changes (#35, ADR 0021). **Propose**
beside Send (View › Propose Changes, ⇧⌘P; `^P` in the terminal) sends
the draft — or, empty, a default request — as a schema-constrained
proposal turn, and a local model may end an ordinary answer by asking
to propose, in which case sai runs that turn itself. Suggestions land
in a lane beside the transcript — move to Someday or a date, set or
clear a deadline, split a task into parts — each naming its task and a
short reason; nothing changes until you accept one. Accepting applies
through the ordinary commands, recorded in the archive as the
assistant's change referencing the proposal and your acceptance, and
one undo reverses it (a split included); rejecting records that too. A
suggestion whose task changed since the proposal shows as stale and can
only be rejected. In the terminal, Tab reaches the lane while a
proposal is shown — arrows move, `y` accepts, `n` rejects, Esc goes
back. Proposals need a local provider: the handles the model uses to
name tasks live in the catalog, which never goes to the cloud.

## Importing from Things 3

`sai_tui things import --dry-run` shows what the archive would gain from
the Things 3 database on this Mac; without `--dry-run` it writes it, as
`system` events carrying each item's Things uuid, so a second run adds
only what changed. Things is never written to — the command reads a
private copy — and the report is counts only (`--db <main.sqlite>` or
`SAI_THINGS_DB` names another file). Repeating rules, reminders,
completed projects and the Trash are reported, not imported. For a
fresh start rather than a mirror, `--open-only`, `--skip-repeat-history`
and `--logbook-since YYYY-MM-DD` leave finished tasks behind (and say how
many); the mapping is in `docs/tasks/task-model-v0.md` § Imports.

The arrow keys walk the workspace (#89): `↑`/`↓` move through the sidebar
rows, `→` enters the list (or unfolds a folded area) and `↑`/`↓` then move
through its rows across the headings, `←` comes back to the sidebar row (or
folds the area). A text field, a dialog or an open menu keeps its own arrows.

The task inspector (#74) opens on the selected row (⌘I opens it on the
first row) and edits in place: a field commits when it is left, so every
edit is one archive event and one undo step. Areas, projects and headings
are organised from the sidebar rows' `…` menu (or a secondary click) and
a project view's heading headers; tags from the inspector's `Manage…`.

A task moves in two independent dimensions (#98): **Move / Schedule…**
(`⇧⌘M`, the row's `…` menu or a secondary click, the Task menu, the
inspector) schedules it — Today, Tomorrow, Someday, a date, no plan — or
files it under the Inbox, any live area or project, or any project's
heading; one pick, one event, the other dimension and the deadline
untouched. Order is a drag by the handle every reorderable row carries —
tasks in Today, the Inbox and each project, heading or area group;
headings within their project; areas; projects within their area or the
standalone group — or `⌘↑`/`⌘↓` (Move up / Move down in the menus). The
slot opens as a red rule; under Reduce Motion it appears in one frame.
A drop across groups, or on a stale row, writes nothing and the top bar
says why.

## Verify

Same commands CI runs, from the repository root:

```sh
dart format --output=none --set-exit-if-changed packages apps/sai_tui apps/sai_app/lib apps/sai_app/test
dart analyze --fatal-infos packages apps
(cd packages/sai_core && dart test)
(cd apps/sai_tui && dart test)
(cd apps/sai_app && flutter test)
swift tool/app-icons.swift check         # macOS
(cd apps/sai_app && flutter build macos --debug --flavor stable)
(cd apps/sai_app && flutter build macos --debug --flavor dev)
dart build cli -t apps/sai_tui/bin/sai_tui.dart --root-package=sai_tui -o build/tui
dart build cli -t apps/sai_tui/bin/sai_tui-dev.dart --root-package=sai_tui -o build/tui-dev
sh tool/test/install_local_test.sh       # the installer, both flavors, against temporary roots
sh tool/test/release_sign_test.sh        # the signing phase, with a fake security/codesign on PATH
gitleaks git . --config .gitleaks.toml   # no secret in any commit
```

`sai_core` must stay free of Flutter: its tests fail if `lib/` imports
`package:flutter` or `dart:ui`, or if its pubspec declares a Flutter
dependency.

The app's widget tests compare goldens under `apps/sai_app/test/goldens/`
(macOS only, where CI runs them — on the `macos-26` image; `test/flutter_test_config.dart` loads the
bundled fonts and the system face from `/System/Library/Fonts` first so
the pixels are deterministic on that release, ADR 0020). A change that moves
pixels re-records them deliberately, one file at a time, and the PNG diff is
reviewed by eye — a regenerated golden asserts the new pixels are right, it
is not a way to turn a red test green:

```sh
cd apps/sai_app && flutter test --update-goldens test/workspace_test.dart
```

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
