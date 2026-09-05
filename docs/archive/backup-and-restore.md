# Backup and restore — a second copy of the archive, and the way back

Status: current · Issue: #15 · ADR: [0025](../decisions/0025-the-archive-is-replicated-to-a-second-root.md) · Spec: [event-log-v0](event-log-v0.md)

The archive is the record; everything else is rebuilt from it (ADR
0004). This document says what a replica is, how sai keeps one, and the
drill that proves a replica can be put back — run once for #15, and
worth running again whenever the disk under the archive changes.

## What a replica is

A replica is a second root with the same layout as the archive —
`MANIFEST.json`, `HEAD`, `events/<day>.jsonl` — on another disk of this
Mac: an external volume, a second internal disk, a mount. It is a
*prefix copy*: every day file is byte-identical to the source's as of
the copy, `HEAD` is the source's `HEAD`, and the manifest's `created`
is the archive's identity. `LOCK` is per location and never copied. The
settings file and the Keychain items are not in it: a backup never
holds a key (ADR 0008), and settings live beside the archive, not in it
(ADR 0006).

A replica is only ever behind its source. sai refuses — and writes
nothing — when the destination holds another archive (a different
`created`), a day file the source lacks, a longer day file, a shorter
one that is not a byte-for-byte prefix of the archive's, or a
same-length newest file that ends in another line. There is no "make it
match": overwriting a replica that disagrees would be the delete the
log forbids. The destination is never the archive itself, a place
inside it, or a place that contains it.

## Keeping one

Set the destination once, from either client:

```sh
sai_tui archive backup-dir /Volumes/Backup/sai     # an absolute path
sai_tui archive backup-dir                         # show it
sai_tui archive backup-dir none                    # forget it
```

or on the app's Settings › Archive page, *Back up to*. From then on:

- **While sai runs**, either client copies on its own: 30 s after it
  starts and 30 s after the log last grew, one copy at a time. The
  Archive card's status line says what the last copy did — `backed up:
  1,204 lines, every hash matches · 09:14`, `skipped: the destination
  is not mounted`, or `failed: …` naming the reason and a file's name,
  never a line. *Back up now* copies at once.
- **While sai is closed**, the dogfood install's LaunchAgent
  (`~/Library/LaunchAgents/me.slominski.sai.backup.plist`, `…sai.dev…`
  for dev) runs `sai_tui archive backup` every hour, logging to
  `~/.local/share/sai/backup.log`. It exits at once while no destination
  is set. `launchctl kickstart -k gui/$(id -u)/me.slominski.sai.backup`
  runs it now; `launchctl print gui/$(id -u)/me.slominski.sai.backup`
  shows it is loaded.
- **By hand**, `sai_tui archive backup` copies to the configured
  destination; `sai_tui archive backup <dir>` to another one, without
  remembering it.

Every copy begins with the full chain walk of the archive — a torn tail
or a broken chain stops it before a byte of the replica is replaced, and
the last good copy stands — and ends with the same walk against the
replica: every line hashed, every `prev` checked, `HEAD` matched. A
replica that does not verify is reported, not repaired. An unmounted volume is *skipped*,
exit 0, so the hourly job stays quiet until the disk is back.

Time Machine backs the replica up like any other folder on a volume it
covers, and not at all on one it does not; sai neither excludes nor
includes it (ADR 0025).

## Verifying

```sh
sai_tui archive verify                  # the live log
sai_tui archive verify /Volumes/Backup/sai
```

prints `verified: <count> lines, head sha256-…` or fails naming the
file and the line. Without sai, per the spec: every line's id is the
SHA-256 of its exact bytes, and each line's `prev` is the id of the
line before it:

```sh
cd /Volumes/Backup/sai/events
cat *.jsonl | while IFS= read -r line; do printf '%s' "$line" | shasum -a 256; done
```

## The restore drill

Run in a scratch environment — never the real data directories — with
`SAI_ARCHIVE_ROOT=<dir>/archive SAI_SETTINGS_FILE=<dir>/settings.json`
on every command (AGENTS.md, Manual smoke). Evidence is the counts and
the HEAD lines, **results, not claims**.

1. **Seed.** Put a few events in the scratch archive — capture tasks in
   the terminal client (`tool/smoke/tui.py` drives it through a pty) or
   the app. `sai_tui archive verify` prints the count. Evidence: the
   count and the head id.
2. **Copy.** `sai_tui archive backup-dir <dir>/replica`, then `sai_tui
   archive backup`. Evidence: `backed up: N lines to … (k files, b
   bytes copied)`, N equal to step 1.
3. **Check the replica without sai.** `cmp <dir>/archive/HEAD
   <dir>/replica/HEAD` is silent; `shasum -a 256 <dir>/archive/events/*`
   and the same over `<dir>/replica/events/*` list the same digests.
   Then `sai_tui archive verify <dir>/replica`. Evidence: the two digest
   lists, the verify line.
4. **Wipe.** `mv <dir>/archive <dir>/archive.lost`. The log is gone.
5. **Restore.** `sai_tui archive restore <dir>/replica`. Evidence:
   `restored: N lines into <dir>/archive, every hash checked`.
6. **Prove it.** `sai_tui archive verify` prints the same count and head
   id as step 1; `cmp` of every day file against `archive.lost` is
   silent (HEAD carries the restore's own `updated`, its count and head
   are the replica's); the client opens and shows the tasks. Evidence:
   the verify line, the silent `cmp`s, a screenshot or the TUI's list.
7. **Restore refuses a live log.** `sai_tui archive restore
   <dir>/replica` again fails with `the archive root is not empty: move
   it aside, then restore`; HEAD's count and head are what step 6
   printed. Evidence: the message and `cat HEAD`.

### Runs

| date | events | replica | wiped and restored | notes |
| --- | --- | --- | --- | --- |
| 2026-09-05 (#15) | 13 in one day file, seeded through `tool/smoke/tui.py` | 1 file, 8,406 bytes copied; HEAD and the day file `cmp`-identical, 13 line ids by `shasum`, `archive verify <replica>` 13 | `restored: 13 lines … every hash checked`; verify 13 with the same head; day file identical to the wiped one; the TUI lists the four tasks | a second restore refused: `the archive root is not empty` |
