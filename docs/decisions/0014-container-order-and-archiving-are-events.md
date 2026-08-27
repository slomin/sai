# 14. Container order and archiving are events, not view rules

Date: 2026-08-26 · Status: accepted · Issue: #74 · Builds on: [0004](0004-the-task-store-is-event-sourced.md)

## Context

Through #72 the sidebar sorted areas and projects by title and a project's
headings by creation time, computed at read time; the task model said so
("task order is the only persisted manual order in this version"). The
only container lifecycle was soft delete, and a deleted container's tasks
simply vanished from every list — not in the Trash, not anywhere.

#74 builds the organisation controls. A person who drags "Home" above
"Work" expects it to stay there, a title sort cannot coexist with that,
and putting a finished project away should not make its tasks
unreachable. Both wants are state the log must carry; neither is a view
rule.

## Decision

Areas, projects and headings get a persisted manual order carried by
three new archive events — `area.reorder`, `project.reorder`,
`heading.reorder`, each a subject plus a required nullable `after` —
replayed into three projection sequences exactly as `task.reorder` and
`task.move` build the Today and structural sequences, replacing the title
and creation-time sorts the sidebar and views computed at read time.
Areas and projects also get a soft `archived` state through
`area.archive`/`area.unarchive` and `project.archive`/`project.unarchive`:
an archived container leaves the sidebar's main groups and hides its
tasks like a deleted one, keeps every placement and its position in the
sequence, refuses new members, and stays browsable through the
projection's archive queries until it is unarchived. There is still no
project completion and no `heading.archive`, and heading ownership stays
fixed: the vocabulary grows from 26 to 33 additive types with no envelope
version bump, and every existing log replays into creation order with
nothing archived.

## Consequences

- Every existing sidebar re-orders once, from title order to creation
  order, the first time the new build opens it. Intended: from then on
  the order is the person's.
- A project's group is still its area, changed only through
  `project.edit`; a changed area appends the project to the end of its
  new group, and undoing that restores the area but not the slot.
- A `project.reorder` carries no group key; `task.reorder` carries
  `list:"today"` because lists may grow, containers have one order each.
- An older sai reading a newer log skips the seven types
  (`decodeTaskEvent` returns null for unknown types) and shows archived
  containers as live — acceptable for a single-user local archive.
- The Things importer treats an area or project archived in sai like a
  deleted one: it leaves it alone, counts it under
  `Unsupported.archivedInSai`, and imports its contents unfiled.
- Tags keep no order and no archived state; a tag is deleted or live.

## Alternatives rejected

- **Keep the title sort and drop the reorder bullets.** The ticket's
  "sidebar containers and headings retain their persisted order" is the
  product; a deterministic sort would have been a smaller PR and a worse
  sidebar.
- **Archive as soft delete plus a task-move dialog.** Simpler, but a
  put-away project would lose its structure, and restoring it would mean
  moving tasks back by hand.
- **Hide a project transitively when its area is archived.** A live
  project inside an archived area would then appear in no query at all;
  listing it standalone (as under a deleted area) keeps every project
  reachable.
