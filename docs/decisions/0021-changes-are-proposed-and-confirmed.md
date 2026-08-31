# 21. Changes are proposed, confirmed and only then applied

Date: 2026-08-31 · Status: accepted · Issue: #35 · Builds on: [0007](0007-provider-traffic-is-three-events-per-call.md), [0010](0010-the-privacy-policy-is-a-switch-checked-in-the-recorder.md), [0011](0011-context-is-assembled-once-and-hashed-as-sent.md)

## Context

The assistant reads the list and, until now, could not touch it. #35
makes it a safe helper: it may suggest a change — reschedule, a
deadline, a split — but a person decides. The pieces that needed
deciding: how a suggestion travels the wire reliably on small local
models, how the model names a task without ids ever entering a prompt,
how the record stays honest, and how a suggestion is kept from acting
on a task that changed under it.

## Decision

- **Structured output, not tool calling.** A proposal turn carries
  `response_format: json_schema` (`sai_proposal_v0`, versioned in
  `src/proposals/schema.dart`), the one mechanism llama-server, LM
  Studio and the OpenAI wire all read. The schema stays inside the
  subset llama.cpp converts to a grammar — types, enums, required-only
  objects, anchored patterns — pinned by test. Output that fails to
  parse or validate is a failed proposal turn: one `proposal.refused`
  line, nothing shown, no repair pass.
- **Two triggers, one constrained call.** The person asks (Propose /
  ⇧⌘P / `^P`), or the model ends an ordinary answer with
  `<sai:propose/>` alone on the last line — sai strips the line from
  display and history (the ADR 0018 hold-back, generalised), flags the
  `chat.message` with `proposes: true`, and runs the schema-constrained
  follow-up itself. The decision to act is never made under the
  grammar: constrained decoding measurably suppresses it on small
  models (arXiv 2606.25605), and our LAN Qwen confirmed the split works.
  A mid-text marker is ordinary text; that CommonMark renders it as an
  autolink-shaped span is accepted.
- **Turn-local handles.** The catalog numbers its Open entries
  (`- [t1] …`) as a pure function of the projection, so the warmed
  prefix still serves every turn; the handle→id map lives in the turn's
  locals and nowhere else. A proposal call therefore needs the catalog:
  cloud providers are refused, and ids still never enter a prompt.
- **The record.** `proposal.made` (assistant, `model`, ids resolved,
  `refs` → the response and the triggering line); `proposal.accept` /
  `proposal.reject` (user, the item index); the applied mutations are
  ordinary task events, actor `assistant`, `refs` naming the proposal
  and the acceptance — `proposals/apply.dart` is the one production
  caller of `Attribution.assistant`, pinned by
  `no_assistant_mutation_test` along with the chat, llm and context
  layers never importing the store. An acceptance whose mutation never
  followed is a change that was not made.
- **Stale means refused.** Every suggestion fingerprints its target's
  `modifiedAt`; the lane derives staleness against the live projection
  and a stale accept writes nothing. The fingerprint is checked twice:
  at the lane for the refusal sentence, and again atomically inside the
  serialized store command (`ifModifiedAt`), so an edit racing an
  acceptance fails the item instead of being overwritten. One accept is one undo entry —
  `splitTask` groups its events (parts created, original to the Trash)
  under a single inverse list.
- **The lane is session state.** A new proposal replaces the last;
  superseded pending items were never acted on and write nothing. The
  archive is the record, as everywhere.

## Consequences

- The profile stops saying "You cannot change the list" and teaches
  the marker instead; both clients gained a lane, a propose action and
  the proposing wait state.
- `provider.request` records `response_format` raw; `context_hash`
  still names the messages alone.
- A schema the endpoint refuses (400) is a rejection with fixed text,
  never a retry without the grammar.
- Rejected: tool calling (a second per-model template dependency for
  no gain here — and the constraint-tax literature argues the same
  split we shipped); making every turn structured (kills streaming
  Markdown and burdens plain questions); proposing from the compact
  context (would put handles into cloud-visible bytes #105 froze).
