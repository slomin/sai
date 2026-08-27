# 2. Retire the Go prototype from `main`

Date: 2026-08-23 · Status: accepted · Issues: #1, #11

## Context

sai v1 was a Go/Bubble Tea terminal chat client for llama.cpp (last
release v0.1.0, 2025-11-01). v2 is a Dart workspace with a different
product: a task list with an assistant, two clients over one core (#9).
Nothing from v1 carries over except lessons, recorded in
`spikes/nocterm_spike/DECISION.md` and the issue tracker.

## Decision

Remove the Go sources, scripts, docs and the tag-triggered Go release
workflow from `main` in one ordinary commit. Do not rewrite history. The
prototype stays reachable at annotated tag `go-final`, branch
`archive/go-bubbletea`, and release v0.1.0 with its binaries.

## Consequences

- `main` builds with the Dart toolchain only; CI has no Go job.
- The Dart line is released by hand with `tool/release.sh` (#42, ADR
  0017); a `v*` tag is created by that script, never by CI.
- Install links frozen in the v0.1.0 notes and in the archived README
  point at `main/install.sh`, which is gone. The script lives at
  `https://raw.githubusercontent.com/slomin/sai/go-final/install.sh`.
- v1 leaves two things on a machine that v2 must not trip over:
  - the binary at `~/.local/bin/sai` (from `install.sh`) or
    `/usr/local/bin/sai` (from `sai_deploy.sh`) — it shadows any v2
    binary of the same name on `PATH`;
  - the config at `~/Library/Application Support/sai/config.json`
    (`os.UserConfigDir()/sai`), which may hold an API key in the clear.
  Uninstall: delete those paths. v2's settings store (#29) must not reuse
  `…/Application Support/sai/config.json` without reading and migrating
  it, or it will silently overwrite a live key.
- Repository metadata that still describes v1 (the GitHub description)
  is updated by hand, outside this tree.
