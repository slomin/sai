# nocterm spike

Throwaway app for [#10](https://github.com/slomin/sai/issues/10): can
[nocterm](https://pub.dev/packages/nocterm) carry the sai terminal client?
Nothing here ships; `DECISION.md` holds the outcome.

What it exercises: a scrollable task list (left) next to a chat pane
(right) that receives a simulated word-chunk stream at ~35-40 chunks/s, vim-style
navigation, a multi-line UTF-8 text input, hot reload, and `testNocterm`
tests.

## Run

```sh
dart pub get
dart run bin/spike.dart                  # plain
dart --enable-vm-service bin/spike.dart  # with hot reload; edit lib/*.dart while it runs
```

Keys: `Tab` switches pane · `j`/`k`/`↑`/`↓` move · `g`/`G` first/last ·
`Enter` (list) asks about the selected task · in the input, `Enter` sends
and `Ctrl+J` inserts a newline · `q` / `Ctrl+C` quit.

Logs (`print`) go to nocterm's log server, not the screen; the port is in
`~/.nocterm/<project-hash>/log_port.<pid>` and the WebSocket path is
`/logs`.

## Probe

`python3 tool/pty_probe.py` runs the app under a pseudo-terminal, streams a
reply, types UTF-8, toggles focus, and reports how much the renderer
actually wrote — the evidence behind DECISION.md criterion 1.

## Test

```sh
dart analyze --fatal-infos
dart format --output=none --set-exit-if-changed .
dart test
```
