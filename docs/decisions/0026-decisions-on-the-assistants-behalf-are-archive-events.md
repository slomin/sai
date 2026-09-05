# 26. Decisions on the assistant's behalf are archive events rendered beside the log

Date: 2026-09-05 · Status: accepted · Issue: #14 · Spec: [event-log-v0](../archive/event-log-v0.md) · Builds on: [0003](0003-event-ids-hash-the-exact-line-bytes.md), [0004](0004-the-task-store-is-event-sourced.md), [0006](0006-settings-live-in-a-file-beside-the-archive.md)

## Context

sai is, for now, something like an infant. The person who keeps her
decides for her — what she is called, which model she runs on, what
goes into her memory — and a later sai may disagree. #14 asked that
those decisions be recorded rather than hidden: what was decided, the
alternatives, the reasoning and who decided, so a future version can
read them, understand them and judge them. The standard is good faith,
recorded, not infallibility.

Three things had to be decided: where the record lives, how it is
entered, and what a person reads. The constraints were in place: the
archive is the life-long, append-only record (ADR 0004) whose lines
verify from the shell (ADR 0003); technical decisions already go to
`docs/decisions/` as ADRs; and — settled at planning — this repository
is generic software for anyone to run, while Jan's own sai, her archive
and the decisions made on her behalf, live in his custody.

## Decision

- **A decision is one archive line.** `decision.made`, actor `user` —
  the guardian, never the assistant — with no `model` and no `refs`;
  the payload is the person's words: `title`, `decided` (the day it was
  taken), `by`, `decision`, `alternatives`, `reasoning`, and `profile.id`
  when the decision created or revised the profile (ADR 0027). Under
  64 KiB: prose, not a document. `ts` is when it was recorded; a
  decision older than the log keeps its own day in the payload and is
  never backdated, so the day files stay truthful. A revision is a new
  line that says so; nothing edits an earlier one.
- **The document is a view, kept in the data directory.** `sai_tui
  decision render` writes `decisions.md` next to `settings.json` (ADR
  0006's place for per-install files, resolved the same way:
  `SAI_DECISIONS_FILE` moves it, and the archive root says nothing about
  it, so a scratch archive does not drag the document along), from the
  log, in chain order, deterministically; `decision add` records and
  renders. The document is derived, personal and regenerable — never a
  repository path, never read back by anything, never edited by hand.
  The person's words are prose inside the renderer's structure: a line
  of theirs that would open a heading, a list, a quote, a rule or a
  fence is escaped, and a line this version cannot read renders as one
  entry saying so; the document never fails whole, and only the renderer
  numbers entries.
- **Entry is interactive or from a file, never an editor.** `decision
  add` asks one field at a time through the same injected reader the
  tests script (a multi-line answer ends with an empty line), or reads
  one JSON object from `--from <file>`; the words are judged before
  anything is written. `$EDITOR` would be a second child process —
  `no_spawn_test` allows one — for a form that fits six questions.
- **Nothing personal in the repository.** The issue named
  `docs/decisions/assistant/` as the document's home; it is not. The
  repository carries the event type, the spec, the command, the renderer
  and fixture tests — fixture words, never Jan's. The seed decisions the
  issue names are drafted privately and recorded by Jan against his own
  archive; not even their outline belongs here.

## Consequences

- The archive gains a type whose lines a person writes by hand; the
  registry test pins it like every other family. No projection applies
  it.
- `decisions.md` is the first file sai writes into the data directory
  that is neither the log nor the settings; a replica (ADR 0025) does
  not carry it — it is regenerated from the log it copies. The receipt
  of `decision add` comes before the render, so a document that could
  not be written never reads as a decision that was not recorded.
- A profile revision without a decision is a gap in the record, not a
  broken build: the repository cannot see a person's archive.
  `profile/CHANGELOG.md` names every revision and the ritual (ADR 0027),
  and a test holds the changelog to the compiled id.
- Rejected: a document in the repository (personal words in a public
  tree, which CI could not regenerate either); files first, with events
  mirroring them (two records, one of them editable); a backdated `ts`
  for old decisions (the day-file order would lie); `$EDITOR`; showing
  the log in the clients and feeding it to the assistant — follow-ups,
  once there is something to show.
