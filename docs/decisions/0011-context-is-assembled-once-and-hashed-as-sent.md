# 11. Context is assembled once and hashed as sent

Date: 2026-08-25 · Status: accepted · Issues: #33, #34 · Schema: [event-log-v0](../archive/event-log-v0.md)

## Context

The first conversation (#34) needs the assistant to see the task list,
and every later caller — the daily plan (#36), the propose lane (#35),
the terminal client (#41) — needs the same view built the same way,
or the model's answers become untraceable: which list, in which order,
cut where? #33 asked for one function, tested against fixtures, with a
hash on the request event and a documented budget. #31 (the profile)
and #32 (memory) are not built; they are inputs to this function, not
prerequisites for it.

ADR [0010](0010-the-privacy-policy-is-a-switch-checked-in-the-recorder.md)
put the privacy check in the recorder and asked #34 to carry the list on
`LlmRequest.taskContext`, never in a message of its own. #33's wording
("privacy applied inside assembly") predates that decision.

## Decision

- **One function.** `assembleContext` in `sai_core/src/context/` builds
  the whole request for a turn: `system` profile, `system` memory when
  there is any, the conversation so far, the user's line — and the
  lists on `taskContext`, apart from the messages, exactly as ADR 0010
  requires. Pure and deterministic: no clock, no I/O, the same inputs
  give the same request. Clients never build a request themselves.
- **Profile and memory are slots.** Until #31 lands the profile is a
  constant in core (`defaultProfile`); memory is absent until #32. The
  function's signature does not change when they arrive.
- **The lists are what the user sees.** `taskContextFor` renders Today
  and Upcoming with the same `formatQuickCapture` lines and the same
  per-day grouping as the clients (`taskView`), so the model and the
  user read the same text. Empty lists say so rather than vanish.
- **The hash names what was sent.** `context_hash` on every
  `provider.request` is the sha256 blobref of the messages *as sent* —
  after the recorder's policy decision, with the task context in its
  system-message place or absent. Hashing the pre-policy assembly would
  name text the model may never have seen; hashing the projection would
  name data, not the prompt.
- **A budget with a fixed cut order.** With no tokenizer in the
  repository the estimate is one token per four bytes, against a
  default 8 000-token window with 1 024 kept for the answer (also the
  request's `max_tokens`). Over budget, cuts go: the oldest turns (in
  pairs), then Upcoming days from the farthest back (the text says how
  many were cut), then memory. Today and the profile are never cut;
  past that the send is refused and the client says so. What was cut is
  on the result (`dropped`) for the client to show.
- **The conversation is its own record.** Each turn writes
  `chat.message` (user, before the call) and `chat.message` (assistant,
  after it, with `model` and `refs` → its `provider.response`, and
  `finish` — a cancelled answer's partial text included). The three
  provider lines stay the raw wire audit; the chat lines are what the
  user read. A failed call has no assistant line: its `provider.failure`
  is the answer. One conversation per client process; the archive is
  the only persistence.

- **Reasoning is carried apart and recorded.** Backends that think
  aloud (LM Studio's `reasoning_content`, OpenRouter's `reasoning`)
  stream it on the same connection; the transport keeps it apart from
  the answer (`LlmDelta.reasoning`, `LlmResult.reasoning`), the
  recorder writes it on `provider.response` as `reasoning` (capped at
  128 KiB, marked when cut), and a `show_reasoning` setting — off by
  default, View › Show Reasoning (⌘R) in the app, `sai_tui reasoning
  on|off` — decides whether the clients show it. It is never part of
  the conversation history sent back, and never in `chat.message`.

- **History is governed like the list.** An assistant turn that saw the
  list may quote it, so when the policy withholds the list from the
  target provider those turns are left out of the history too (the
  user's own words stay). The recorder remains the check on the wire;
  this is assembly applying the same answer one step earlier.

## Consequences

- `chat.message` gets its first producer (`ChatNotifier`), a payload
  row, and a registry test; `provider.request` gains `context_hash`.
- #33's "privacy inside assembly" is superseded by this ADR: assembly
  keeps the list apart, the recorder decides, the hash records the
  outcome.
- #31 replaces `defaultProfile` with the `profile/` files; #32 fills
  `memory`; neither touches the recorder or the hash.
- An endpoint-aware budget (LM Studio and llama.cpp expose the context
  window on probe) is a follow-up: the probe is unrecorded network
  traffic and a chat turn should not trigger one.
- Rejected: per-client assembly (two clients, two prompts, one bug
  twice); putting the list in a message from the caller (ADR 0010
  could not withhold it); persisting the transcript outside the archive
  (a second store for what the log already holds).
