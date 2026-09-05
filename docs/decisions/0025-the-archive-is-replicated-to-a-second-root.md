# 25. The archive is replicated to a second root

Date: 2026-09-05 · Status: accepted · Issue: #15 · Spec: [event-log-v0](../archive/event-log-v0.md), [backup-and-restore](../archive/backup-and-restore.md) · Schema: [settings-v0](../settings/settings-v0.md) · Builds on: [0004](0004-the-task-store-is-event-sourced.md), [0006](0006-settings-live-in-a-file-beside-the-archive.md)

## Context

The archive is the life-long record; the task store and every index are
projections of it (ADR 0004) and can be rebuilt from it — but only while
it exists. It can prove its own integrity (`Archive.verify`, #40), yet
until now nothing copied it: one failed disk erased the history, and the
release notes pointed at Time Machine and a copy by hand while sai was
quit. The archive must not depend on one disk.

Three things had to be decided: what a replica is, who makes it, and how
it is put back. The constraints were already in place — the log is never
rewritten, `sai_core` starts exactly one child process (the App Server,
ADR 0023) and every other spawn is pinned by `no_spawn_test`, secrets
live in the Keychain and nowhere else (ADR 0008), and an app launched
from the Finder has no environment to read a path from.

## Decision

- **A replica is a prefix copy of the root, verified in place.**
  `Archive.replicateTo` first proves the archive under its own lock —
  the tail against HEAD, then every line — so a torn tail or a broken
  chain stops before a byte of the replica is replaced and the last
  good copy stands; then it copies `MANIFEST.json`, every day file the
  replica lacks or that has grown since, and a byte-equal `HEAD`, and
  runs the full chain walk against the replica — the same check
  `verify` runs — before it reports. `LOCK` is per location and never
  copied; the settings file and the Keychain items are not in it (ADR
  0006 kept settings out of the root for exactly this reason, and a
  backup never holds a key). A replica is only ever *behind* its source:
  a destination whose manifest names another creation time, that holds
  a day file the source lacks, a longer day file, a shorter one that is
  not a byte-for-byte prefix of the archive's, or a same-length newest
  file that ends in another line is refused as diverged, and nothing is
  written. The manifest check and the sweep of this routine's own
  leftover temp files happen under the replica's lock, so two copies
  queued on one replica see each other's work, never a half-written
  file of their own swept away. There is no "make it match" path — overwriting a replica
  that disagrees would be the delete the log forbids.
- **Copies run under both locks, the replica's first.** The source lock
  is held for the HEAD read and the copy, as `verify` holds it for a
  walk, so a copy never catches a half-written line or a HEAD ahead of
  its bytes; only the newest day file grows, so the locked region is one
  day's tail. The replica's lock is taken first and the source's inside
  it: the two replicators (the app and the hourly job) serialize on the
  replica, and the writer — which takes only the source lock — never
  waits behind a whole copy. Copies run on the main isolate in 1 MiB
  chunks with a turn between them; the store's gate is per isolate.
- **Restore goes only into an empty root.** `Archive.restore` reads the
  replica in place — never opens it, so it gains no LOCK and its HEAD is
  never rewritten — walks it end to end, and copies it into a root that
  holds no events; a damaged root is moved aside first. A replica whose
  HEAD is a truthful prefix of its chain (a copy interrupted before HEAD
  was written) restores, rolled forward in the copy. A HEAD-only repair
  of a live root is not offered: the drill is the documented way back.
- **The destination is a setting, and sai copies on its own.**
  `settings.archive_backup` holds one absolute path on this Mac — an
  external volume, a second disk, a mount — never the root, never
  inside it, never above it. While it is set, a core notifier both
  clients run copies 30 s after the process starts and 30 s after the
  log last grew, one copy at a time, and the Archive card shows what the
  last copy did: the count, a time, a reason — never a line, never a
  path. A destination that is not there (an unmounted volume) is
  *skipped*, quietly, and tried again next time.
- **The hourly job is the installer's, not the app's.** The dogfood
  install registers one LaunchAgent per flavor
  (`~/Library/LaunchAgents/<bundle id>.backup.plist`) that runs the
  installed client's `sai_tui archive backup` every hour — the same copy
  from outside the process, for the hours sai is closed. It exits at
  once while no destination is set, never runs at load, and is unloaded
  for the swap and loaded again after it; a bootstrap that fails (no GUI
  session over ssh) is a warning naming the command, never a failed
  install. Tests never reach the real `launchctl`: a fake on PATH records
  every call.
- **Local paths only.** rsync or ssh from sai would be a second child
  process — a new allowlist entry, an inherited SSH agent in the
  environment, a person-run smoke — for a first version whose purpose is
  one more disk. A NAS is reachable as a mount, and the replica verifies
  there like anywhere else; the live root stays on a local disk as the
  spec requires.
- **Time Machine: the replica is neither excluded nor specially
  included.** The archive is megabytes; a second copy in Time Machine
  costs nothing measurable, and excluding it would need `tmutil` (a
  spawned process) or the exclusion xattr (FFI) for no benefit. A
  replica on a volume Time Machine does not back up is simply not in
  Time Machine. Recorded here, not coded.

## Consequences

- One failed disk no longer erases the history: the replica is at most
  30 s behind while sai runs and an hour behind while it does not, and
  the drill in `docs/archive/backup-and-restore.md` — run once for #15,
  results in the doc — is the way back.
- Every replication walks the whole archive and then the whole replica.
  That is milliseconds at today's sizes and stays so for years of tasks;
  an incremental tail check (walk from the last verified id) is the next
  step when a copy starts to cost, and changes nothing in the format.
- `sai_tui archive verify [<root>]` exposes the integrity walk from the
  shell for the first time, so a drill needs nothing but the client — or
  nothing at all: `shasum -a 256` per line, per the spec.
- The settings file gains one key, omitted while unset, so an untouched
  file stays byte-identical; an older sai carries it through untouched.
- Rejected: an archive event per backup (the replica would then always
  lag its source by the line that records it); a Finder folder picker in
  the app (a new plugin for one field — the row takes a path, the CLI
  takes the same); rsync over ssh (above); a launchd job installed by
  the app itself (the installer owns what lives outside the data
  directory, and can remove it).
