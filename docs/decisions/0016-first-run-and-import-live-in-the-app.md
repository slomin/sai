# 16. First run, Settings and the Things import live in the app

Date: 2026-08-27 · Status: accepted · Issue: #40 · Builds on: [0001](0001-macos-app-runs-without-the-app-sandbox.md), [0006](0006-settings-live-in-a-file-beside-the-archive.md), [0015](0015-the-workspace-is-restored-from-settings.md)

## Context

#40 gives the app its Settings surface, a first-run choice — start
empty, or preview and import Things 3 data — and a header light that
says whether the active provider will answer. Four things had to be
decided: how the app knows a first run is over, where the import flow's
state lives, how the light is driven, and how the app reaches the
Finder without starting a process.

## Decision

**Setup is a settings key, written on the choice.** `settings.json`
gains `setup: "done"` (`docs/settings/settings-v0.md`), written when
the person clicks Start empty or finishes an import — a deliberate act,
so the one write a first launch makes is warranted, and an untouched
launch still writes nothing (ADR 0015's rule). The welcome shows while
the key is absent and the archive holds no events; a refused write (a
newer sai's file) is said in the bar and the welcome still goes for
that run, so nobody is trapped in it.

**The import flow is a core notifier.** `thingsImportProvider` walks
locate → source → preview → run → done or failed as a closed state set,
one step at a time, with the snapshot the preview read being the one
written. The failures are a closed set too (`ThingsFailure`), each with
a headline and a next step, so a client never invents copy from an
exception. State carries counts, paths and a Things uuid at most; the
dry-run listing that names titles stays a terminal-only thing. The copy
and the SQLite read run on a spawned isolate; every append stays on the
main isolate, where the archive's lock gate lives.

**The light is a polled probe, not a socket.** `connectionProvider`
asks the active provider's endpoint when it is selected, every minute,
on demand and after a call fails; a provider that cannot be probed (the
fake) is ready, and no provider, a misconfigured one or a missing key
is down. It never guesses from connectivity, and it is a notifier
rather than a future provider so a failure lands once instead of being
retried into a long amber. The level is always paired with a word and
spoken in the header's label.

**The Finder is a Runner channel.** `sai/finder` reveals a path and
puts up an open panel; the Swift side owns both. No app code starts a
process — the `no_spawn_test` allowlist is not widened.

## Consequences

- Settings is a route inside the main window, sized like the
  reference, hosting the providers page that used to be a dialog. A
  second window is not a goal.
- `version` stays 0: `setup` is optional and an older sai carries it as
  an unknown key.
- The app reads the Things container again (ADR 0001, amended).
- A widget test gives every run a home of its own and no probe timer;
  the harness holds both overrides.

## Alternatives rejected

- **Deriving "first run" from state alone.** The welcome would return
  on every launch until something is captured — a nag for a person who
  chose to start empty.
- **A separate settings window.** Flutter's stable macOS has no
  supported second window; the pages are the same either way.
- **`open -R` for Reveal in Finder.** Refused by the spawn allowlist,
  and the panel needs the Runner anyway.
