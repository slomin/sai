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
flutter pub get
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

Build a debug app bundle (what CI does): `cd apps/sai_app && flutter build
macos --debug` → `apps/sai_app/build/macos/Build/Products/Debug/sai.app`.

## Verify

Same commands CI runs, from the repository root:

```sh
dart format --output=none --set-exit-if-changed packages apps/sai_tui apps/sai_app/lib apps/sai_app/test
dart analyze --fatal-infos packages apps
(cd packages/sai_core && dart test)
(cd apps/sai_tui && dart test)
(cd apps/sai_app && flutter test)
(cd apps/sai_app && flutter build macos --debug)
```

`sai_core` must stay free of Flutter: `dart test` there fails if a
`package:flutter` import appears under `lib/`, and CI checks the pubspec.

## Git hooks

Commits here carry no tool-generated attribution. Two hooks enforce it:
`commit-msg` strips such trailers, `pre-push` refuses to push commits that
still have them. Enable them once per clone:

```sh
git config core.hooksPath .githooks
```

## The Go prototype

sai v1 was a Go/Bubble Tea terminal chat client for llama.cpp. It is kept
as is at tag [`go-final`](https://github.com/slomin/sai/tree/go-final) and
branch
[`archive/go-bubbletea`](https://github.com/slomin/sai/tree/archive/go-bubbletea);
its last binaries are the
[v0.1.0 release](https://github.com/slomin/sai/releases/tag/v0.1.0). The Go
sources still present on `main` are removed by
[#11](https://github.com/slomin/sai/issues/11); until then, build them with
`go build ./cmd/sai` and test with `go test ./...`.

## License

Mozilla Public License 2.0 — see [LICENSE](LICENSE).
