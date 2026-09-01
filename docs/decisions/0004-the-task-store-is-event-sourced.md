# 4. The task store is event-sourced

Date: 2026-08-23 · Status: accepted · Issue: #13 · Spec: [event-log-v0](../archive/event-log-v0.md)

## Context

The task model (#17) needs a store, and the archive (#12) records every
interaction. Two shapes were on the table: the store as an event-sourced
projection of the archive, or the store as the primary record with
mutations mirrored into the log. The choice decides which artifact is
the truth about the history of Jan's tasks — the question the whole
project exists to answer well.

## Decision

The task store is **event-sourced**. Every task mutation — create, edit,
complete, cancel, move, delete, checklist change — is an archive event
first: appended, fsynced and chained through the log defined in the
event-log v0 spec. Only then is it applied to a local SQLite projection.
The projection is disposable: it can be deleted at any time and rebuilt
by replaying the log, and startup catches it up from the last applied
event. All writes go through `sai_core` commands; there is no second
write path.

What decided it:

- The log already reserves the Perkeep claims vocabulary
  (ADR [0003](0003-event-ids-hash-the-exact-line-bytes.md), spec
  "Reserved for v0.2") precisely so mutable state could become claims
  over immutable events — the substrate direction (#16) assumes this
  shape, and the v0.2 migration maps mutation events onto claims
  directly.
- The costs were measured in #12, not guessed: an append is fsync-bound
  at ~3 ms (~330/s sustained across two contending processes), orders of
  magnitude above human task-mutation tempo; replay verification walks
  the chain at microseconds per line.
- A rebuildable projection matches the doctrine the storage design is
  built on: indexes are disposable, only the log is backed up (#15).
- Undo (#19) and corrections need no store machinery: they are new
  events, as the spec already requires.

## Alternatives

- **Store-primary, mutations mirrored into the log** — rejected: two
  sources of truth. A crash between store write and mirror append makes
  the archive lie by omission, the store cannot be rebuilt if the mirror
  was ever incomplete, and every future consumer must decide which
  record to believe.
- **Dual-write under one transaction** — rejected: there is no atomic
  commit spanning a JSONL append and a SQLite write; building two-phase
  machinery for v0 contradicts the tiny-and-simple bar set in #12.

## Consequences

- #17 defines the task event types in the spec's type registry and the
  projection schema, and implements the store as replay + apply; #19
  routes every mutation through it.
- Startup replay is O(archive). Fine at v0.1 scale; a snapshot
  mechanism is deliberately not designed until replay cost earns it.
- The SQLite file is never a backup target and never migrated — thrown
  away and rebuilt instead.
- Deleting a task deletes nothing: the log keeps the full history, and
  the projection simply stops showing it.

### Amendment (2026-08-24, #17)

The v0.1 projection is **in memory** — full replay at open, apply on
append — not SQLite. The event-sourcing decision, the single write path
and the disposable-projection consequence are unchanged; only the
projection's medium is deferred, tracked in #49, until replay cost or
query needs earn it. The task model and payload contract live in
[task-model-v0](../tasks/task-model-v0.md).

One projection per process means another process's appends reach it
only on a replay. Since #118 (2026-09-01) both clients replay through
one core follower that polls the log's `HEAD` count every two seconds
and reloads only when a line this process did not write has landed —
its own lines, whatever wrote them, never trigger a replay.
