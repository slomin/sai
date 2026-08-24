# The task model, v0

Status: current · Issues: #17, #20 · ADR: [0004](../decisions/0004-the-task-store-is-event-sourced.md) · Registry: [event-log-v0](../archive/event-log-v0.md#task-domain-17)

sai's tasks are the Things 3 subset v0.1 honours: areas, projects,
headings within projects, tags, and tasks with title, Markdown notes, a
checklist, a when-date, a deadline and lifecycle timestamps. Every
mutation is an archive event first (ADR 0004); the store is a projection
replayed from the log. `packages/sai_core/lib/src/tasks/` is the
implementation; this document is the contract for the payloads it writes.

Out of scope for v0.1: sync, attachments, collaboration.

## Identity

**The id of an entity is the id of the event that created it** — the
blobref of the `*.create` line's exact bytes. There is no UUID anywhere.

- Ids are already in the substrate's reference form (`sha256-…`), so the
  v0.2 migration maps a `*.create` event to a permanode and every later
  event about it to claims, with no id remapping.
- Collisions are structurally impossible: two lines cannot be
  byte-identical, because every line carries a distinct `prev`.
- The id is known only after the append returns; payloads therefore never
  contain their own id.

Every non-create event names its subject in `payload` (`task`, `area`,
`project`, `heading` or `tag`) — the only key the reducer reads — and
repeats it in the envelope's `refs` so provenance tooling works without
task knowledge. A `task.move` also refs its destination containers and
an explicit predecessor; `task.reorder` refs its predecessor. Do
not read `refs` back; only the payload is normative.

Subject kind is checked at replay: a `task.edit` whose subject is a
project id refuses the log loudly.

## Entities

| entity | fields |
| --- | --- |
| Task | title, notes (Markdown), when, deadline, placement (project / area / heading), tags, checklist, created/modified/completed/cancelled/deleted timestamps, external |
| Project | title, notes, area?, when, deadline, tags, timestamps, external |
| Heading | project, title, timestamps |
| Area | title, timestamps, external |
| Tag | title, parent?, timestamps |

- A task lives in a project, in an area, or nowhere — never two at once;
  a heading placement implies the heading's project.
- Status (open / completed / cancelled) is derived from the timestamps,
  never stored. Completing sets `completedAt` and clears `cancelledAt`;
  cancelling does the inverse; reopening clears both.
- `modifiedAt` is always the timestamp of the last applied event about
  the entity; it can never be supplied.
- Deletion is soft everywhere: `deletedAt` set, history kept, projection
  queries stop showing it. Restore clears it. The log deletes nothing.

## Dates and instants

- **Calendar days** (`when`, `deadline`): `"2026-08-24"` — no time, no
  zone. "Today" is the *local* calendar day of the machine asking;
  comparing instants to days is how todo apps get midnight wrong, so the
  model makes it unrepresentable.
- **Instants** (all timestamps): the log's `ts` form,
  `2026-08-24T09:14:02.123456Z`.
- An explicit creation `created_at` or completion/cancellation `at` must be
  no later than its containing event's envelope `ts`. Equality and earlier
  history are valid; a future instant stops decode and replay.
- **`when`** is `null` (no plan), `"someday"`, or a date. A Things-style
  "this evening" or reminder time would arrive as an additive
  `when_time` key, not a change to `when`.

## Lists

Membership is a pure function of one task and today's date. First match
wins; deleted tasks are in no list (the Trash is a projection query):

| # | condition | list |
| --- | --- | --- |
| 1 | completed or cancelled | Logbook |
| 2 | deadline ≤ today | Today |
| 3 | when is a date ≤ today | Today |
| 4 | when is someday | Someday |
| 5 | when is a future date | Upcoming |
| 6 | unfiled (no project, area, heading) | Inbox |
| 7 | otherwise | Anytime |

Rule 2 outranks Someday deliberately: a Someday item whose deadline has
arrived surfaces in Today (a future deadline leaves it in Someday).

Things renders unions, not a partition, so `listsOf` adds: a *filed*
Today task is also in Anytime, and an open task with a future deadline
also surfaces in Upcoming.

Deliberate divergences from Things, both to keep the pure contract
"task state + today only":

- A project's Someday does **not** propagate to its tasks.
- A task whose project, area or heading is deleted is hidden by the
  projection's queries, not by the membership rules — `listOf` on the
  task alone still answers from its own state.

The projection replays two independent task-id sequences:

- **Structural order** drives Inbox and every area/project/heading group.
  Creation appends to it. A placement move removes the task and inserts it
  in its final group.
- **Today order** drives the flat Today list only. Creation appends to it;
  structural moves never change it, and Today reorders never change
  placement.

Completion/cancellation and deletion filter a task without removing it from
either sequence. Reopen/restore therefore reveals it at its former position.
Upcoming remains chronological. Logbook remains completion-driven. Area and
project sidebar/heading order is deterministic rather than user-controlled;
task order is the only persisted manual order in this version.

`task.move.after` has three wire states: omitted means append in the
destination group (including every pre-#20 move); JSON `null` means first;
an id means immediately after that live sibling in the final Inbox, direct
area, unheaded project, or heading group. Unknown, self, deleted/finished, and
cross-group anchors are refused before append. `task.reorder` carries
`list:"today"` and a required nullable `after` with the same first/after
meaning for Today's independent sequence.

### View shape (#20)

`TaskView` is the immutable shared client model and is keyed by the selected
sidebar section:

- Inbox and Today are one flat section, in structural and Today order.
- Upcoming is grouped by ascending calendar day. A future when-date supplies
  the day; otherwise the future deadline does.
- Anytime and Someday start with loose tasks, then expand live areas and
  projects in sidebar order. Projects contain unheaded tasks followed by live
  headings in creation/id order.
- A project view is its unheaded section followed by those heading sections.
  An area view is its direct-task section followed by every live project and
  that project's unheaded/heading sections. Live empty groups remain present;
  deleted or unknown selected containers produce no sections.
- Logbook groups completed and cancelled tasks by the finish instant's local
  calendar day, newest day first and newest finish first within the day.

`taskViewProvider` and `sidebarProvider` preserve the task provider's loading
and error state and watch both its projection and `todayProvider`.
`todayProvider` schedules local midnight, reads the clock again after a late
sleep/wake callback, reschedules, and cancels its timer on disposal. Thus date
membership changes without a task mutation.

## Events

The 26 types and their actor columns are rows in the
[event log registry](../archive/event-log-v0.md#task-domain-17).
Payloads use the shared value forms:

| form | JSON |
| --- | --- |
| id | `"sha256-<64 hex>"` |
| date | `"2026-08-24"` |
| instant | `"2026-08-24T09:14:02.123456Z"` |
| when | `null` \| `"someday"` \| date |
| checklist item | `{"title":"…","completed_at":instant\|null}` |
| external | `{"system":"things3","id":"…","version":"…"?,"instance":"…"?}` |

Strict optional strings distinguish absence from malformed values: an absent
key uses its default, while a present JSON `null`, a non-string value, or an
empty string where the field disallows emptiness is a `FormatException`.

`*.create` payloads carry only non-default keys. `*.edit` payloads use
**field-set semantics**: a key present sets the field, a JSON `null`
clears it, an absent key leaves it alone — one key per future
`set-attribute` claim. Notes clear to `""`, never to `null`. Placement
never changes through an edit; `task.move` replaces the whole placement,
always writes every placement key, and optionally carries `after`.
`task.reorder` is only Today's independent order. `task.checklist` replaces the
whole ordered list — items have no identity in v0.1; per-item events
would arrive as a new `checklist.*` family.

Every event's inverse is expressible, which is what undo needs —
see [Undo](#undo-19).

Golden vector — this exact line (144 bytes):

```
{"actor":"user","payload":{"title":"Buy oat milk"},"prev":null,"source":"sai/tui","ts":"2026-08-24T09:14:02.123456Z","type":"task.create","v":0}
```

has id `sha256-b9ce5b9c29fed28862c26cb307c88bbf5bd0935ce4df2b382a888eff91fdde4b`.

### Imports

`external` on a `*.create` records where an imported entity came from
and keys the projection's dedupe index — a re-run of the Things import
(#18) finds what it already created instead of duplicating it.
`created_at` is an import-only override of the creation instant and is
valid **only alongside `external`**; `modified_at` can never be
supplied. Imports write as actor `system`.

## Replay

The reducer is one function, run by full replay and by apply-on-append
alike, so the two cannot disagree:

1. An event whose type is outside the task family — `chat.message`,
   `provider.*`, or a type a newer sai added — advances the cursor and
   changes nothing.
2. A family event with a malformed payload stops replay with a
   `FormatException` naming the event.
3. A family event whose subject is unknown, of the wrong kind, or
   violating a placement rule stops replay with a `TaskProjectionError`
   naming the event.

There are no invalid transitions: over well-formed events with known
subjects the reducer is total (completing twice overwrites the stamp,
editing a deleted task applies). The store keeps cases 2 and 3
unreachable through the sanctioned path by validating every command
against the projection before appending.

## Quick capture (#19)

One text line becomes one `task.create`. The grammar is fixed and
total — no line is ever refused:

1. Trim the line; empty captures nothing.
2. Scan trailing whitespace-separated words right to left. Consume a
   recognized token whose kind is not already taken; stop at the first
   word that is no token, or repeats a kind.
3. If consuming would leave an empty title, nothing was a token: the
   trimmed line is the title verbatim.

| token | sets |
| --- | --- |
| `@today` | when = today's date |
| `@tomorrow` | when = tomorrow's date |
| `@someday` | when = someday |
| `@YYYY-MM-DD` | when = that date (strict; a date that does not exist is not a token) |
| `!today` / `!tomorrow` / `!YYYY-MM-DD` | deadline (there is no `!someday`) |

Keywords are case-insensitive; a token must be its own word
(`milk@today` is title text); tokens mid-line stay in the title
(`call @today mom` is a title). There is no escaping in v0.1 — a title
that must *end* in a token form is not expressible; quoting is a later
problem. Worked examples:

- `Buy oat milk` → Inbox.
- `Call mom @today` → when set, so the task surfaces in Today, not
  Inbox (list rule 3 outranks rule 6).
- `x @nope @today` → title `x @nope`, when today (the scan stopped).
- `@today` → a task titled `@today` (rule 3 above).

Capture never files and never tags — an Inbox-shaped task is the
point. The raw line is not recorded; only the parse result is (adding
a payload key for it would be a spec change).

## Undo (#19)

Undo is a new event, never a rewrite: reversing a mutation appends its
**inverse** — an event of the same 26-type vocabulary, computed against
the projection the mutation was validated on — with the reversed
event's id in the envelope `refs`. No new types, no new payload keys.

| event | inverse |
| --- | --- |
| `*.create` | `*.delete` of the minted id — a **soft** delete; an undone create sits in the Trash, the log keeps it forever |
| `*.edit` | an edit writing the prior values of exactly the fields the event set |
| `task.move` | one move restoring the prior placement and predecessor |
| `task.reorder` | one Today reorder restoring the prior predecessor |
| `task.complete` / `task.cancel` / `task.reopen` | whichever of complete-with-prior-`at` / cancel-with-prior-`at` / reopen restores the prior pair |
| `*.delete` / `*.restore` | whichever of restore / delete restores the prior state |
| `task.checklist` | the prior items |

The table is total: a degenerate mutation (deleting the deleted,
reopening the open) inverts to the state-preserving event of its kind,
so a session's N mutations take exactly N undos, unwound newest first.

The stack is session-local — one entry per command this process
committed, no redo, gone when the process ends — and survives a
`reload()`: entries name entities by id, and an inverse a concurrent
writer has invalidated is refused by the same validation every command
passes, keeping its entry for a retry. Undo against concurrent writers
is last-write-wins behind that validation.

Restored exactly: field values, placement, checklist, and the
completion/cancellation instants (they ride in `at`). Not restored:
`modifiedAt` (it bumps to the inverse's own ts) and an older
`deletedAt` overwritten by a delete-again.

## The projection is in memory (ADR 0004 amendment)

ADR 0004 says "SQLite projection"; v0.1 ships the projection **in
memory** — full replay at open, apply on append. The event-sourcing
decision, the single write path and the disposable-projection doctrine
are unchanged; only the medium is deferred, tracked in
[#49](https://github.com/slomin/sai/issues/49), until replay cost or
query needs earn it (#12 measured replay at microseconds per line).

Consequences: one store per process; a concurrent writer's appends
become visible on `reload()` or reopen, not live. Date-derived providers do
roll over at local midnight, independently of archive writes.

## Repeating tasks are deferred

v0.1 models **no repetition rule**. The Things import (#18) materialises
each repeating task's *next instance* as a plain task, carrying
`external` with the **repeater's** id and the occurrence date in
`instance` — so a later re-import, seeing the repeater advanced, updates
the materialised task in place instead of duplicating it. When
repetition earns its way in, rules arrive as new event types against the
same task ids.

Also deferred, with their re-entry paths:

- **Project completion** — no `project.complete` in v0.1; #18 reports
  completed Things projects as unsupported; the type lands when a
  consumer needs it.
- **Per-item checklist events** — a future `checklist.*` family.
