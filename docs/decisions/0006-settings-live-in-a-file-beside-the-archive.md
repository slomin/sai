# 6. Settings live in a file beside the archive

Date: 2026-08-24 · Status: accepted · Issue: #21

## Context

The active LLM provider is an app-level choice that must survive a
restart and switch at runtime (#21). Provider settings proper — named
endpoints, default models, API keys in the Keychain — are #29, and the
privacy switch is #27. Something has to hold the non-secret part now,
in a place both clients (the app bundle and the `dart compile exe` TUI
binary, independently versioned) can read and write.

Three shapes were considered: a file inside the archive root, a
`provider.select` archive event replayed on open, or a plain settings
file next to the archive.

## Decision

Non-secret settings are one JSON file **beside** the default archive,
in sai's data directory: `SAI_SETTINGS_FILE` when set, else
`<data>/settings.json` next to `<data>/archive` (macOS:
`~/Library/Application Support/sai/`; elsewhere `$XDG_DATA_HOME/sai` or
`~/.local/share/sai`). The path does not follow `SAI_ARCHIVE_ROOT`: a
scratch archive in `/tmp` must not drag the settings into `/tmp` with
it — a scratch run that wants scratch settings sets both variables.
`packages/sai_core/lib/src/settings/` is the one reader and writer.

Format, v0:

| key | value |
| --- | --- |
| `version` | `0` |
| `llm` | id of the selected `LlmProvider`, or `null` for none |

Rules:

- **Unknown keys survive a write.** Two binaries of different versions
  share the file; a v0 writer must not erase what a v1 writer stored.
- **Writes are atomic**: a per-process temp file (`settings.json.<pid>.tmp`),
  fsync, rename. There is no lock — the file is a preference, not a
  record — so two clients writing at once are last-write-wins, and a
  change in one running client reaches the other on its next start.
- **Unparseable content is quarantined**: the file is moved aside as
  `settings.json.bad-<ts>`, defaults apply, the clients say so in the
  status line, and the next write starts fresh.
- **A newer `version` is refused, not repaired**: defaults apply and the
  file is left untouched — every write refuses until a binary that
  understands it runs. A newer binary's settings are never destroyed.
- No secret ever goes in this file. #29 puts keys in the Keychain and
  adds a test that scans the file.

Why not the alternatives:

- *Inside the archive root*: the archive directory is the backed-up,
  append-only record (#15); a mutable preference does not belong in it,
  and the archive's no-silent-repair rule would then have to apply to a
  file that records no history.
- *An archive event*: elegant and event-sourced, but selecting a provider
  is not something sai saw or did, #29 needs a settings file regardless,
  and every open would replay the log to find one value.
- *Keychain for everything*: non-secret settings should be readable and
  hand-editable without a prompt.

## Consequences

- `settings.json` holds exactly one key today; #29 grows it (endpoints,
  default models, Keychain references) and promotes this table to
  `docs/settings/settings-v0.md` when it becomes a real schema.
- The quarantine rule is the one place in sai where a malformed file is
  moved rather than reported and left alone. It is safe because settings
  hold no history; nothing here is ever the only copy of anything.
- Test harnesses override the settings path explicitly, next to the
  archive root they already override; both providers read the
  environment through `environmentProvider`, so no exported variable
  reaches a test.
