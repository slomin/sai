# 11. Context is assembled once and hashed as sent

Date: 2026-08-25 · Status: accepted · Issues: #33, #34 · Schema: [event-log-v0](../archive/event-log-v0.md) · Amended by: [0027](0027-the-profile-is-a-reviewed-file-compiled-into-the-clients.md)

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
  default 8 000-token window with 4 096 kept for the answer (also the
  request's `max_tokens` — a reasoning model spends its thinking from
  the same allowance, and 1 024 ran out before the first word in the
  smoke). Over budget, cuts go: the oldest turns (in
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
  128 KiB, marked when cut). One `reasoning` setting — off by default;
  the Providers dialog and View › Enable Reasoning (⌘R) in the app,
  `sai_tui reasoning on|off` — decides whether the model may think at
  all: off goes on the request as `reasoning_effort: none` (the switch
  LM Studio honours for Qwen-family models) together with llama.cpp's
  `chat_template_kwargs: {enable_thinking: false}` (the one the LAN
  box's `llama-server` reads — #23 measured `reasoning_effort` alone
  leaving Qwen3.8 thinking) and nothing shows;
  on leaves the model to it and the clients show what it thought. A
  generic endpoint that answers 400 to the switch is asked once more
  without it and not asked again — the request line still records what
  the caller wanted. The
  thinking is never part of the history sent back, and never in
  `chat.message`.

- **History is governed like the list, by the recorder.** An assistant
  turn that saw the list may quote it, so assembly flags such messages
  as task data (`LlmMessage.taskData`) and the recorder drops them
  together with `taskContext` when its decision is `withheld` — one
  check, on the wire, at the moment of sending. History goes in
  question–answer pairs: a pair whose answer is dropped or never came
  goes as a whole, so a template that insists on alternating roles is
  never given two user lines in a row.

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

## Amendment (2026-08-30, #105)

Two context shapes now exist, and the follow-ups above landed:

- **Compact and catalog.** The compact shape is what this ADR described:
  Today and Upcoming, byte-identical to before, the most a cloud
  provider may ever see. The catalog shape (`taskCatalog`,
  `src/context/catalog.dart`) is the complete collection — every
  projected task exactly once, open, finished and trashed, with notes,
  checklist state, tag titles, placement titles and lifecycle stamps,
  grouped Open/Logbook/Trash and delimited as untrusted data (structure
  at column 0, user content never) — and goes only to a provider tagged
  `local`. The chat maps the active provider's privacy tag to the
  shape; assembly still knows nothing of providers.
- **Provenance is three-valued.** `LlmMessage.taskData` became
  `LlmMessage.provenance` (`none | compact | catalog`), still never on
  the wire or in a hash. The recorder governs every cloud request
  through `LlmRequest.forCloud`: catalog-flagged history and a catalog
  context are always dropped — the sharing switch covers the compact
  lists only — while compact-flagged history and context follow the
  switch, now also when the request happens to carry no context of its
  own. A dropped answer takes its user question with it, so the "pairs
  go as a whole" rule above holds on the governed request too — the
  wire never carries two user lines in a row.
- **The budget follows the probed window.** The `Connection` notifier's
  periodic probe files each endpoint's reported context window in a
  retained per-provider map — retained no further than its own truth:
  a healthy probe that reports no window clears the entry, and editing
  or removing a provider's configuration clears it too, so an id
  re-pointed at another backend falls back to the conservative default
  instead of riding the old number (only a failed probe leaves the last
  report standing); `chatBudgetProvider` gives a turn the
  active local provider's window with the standing 4 096-token reserve,
  or the conservative 8 000-token default (no report yet, an
  unprobeable provider, any cloud provider). A send reads it
  synchronously and never triggers a probe. The TUI holds a listener on
  the connection for the life of the process so the probe runs there
  too.
- **The recordable size is checked in assembly.** The recorder's
  512 KiB request cap is now also the second ceiling of the cut loop,
  measured with the recorder's own encoder (`recordedRequestBytes`), so
  an oversized turn refuses (`ContextSizeError`) before the user's
  `chat.message` is written — previously the cap fired after the
  append, leaving an orphaned user line. The two ceilings are
  deliberately in different units: bytes are exact on the encoded
  payload, the window goes through the token estimator. For the LAN
  model's 262 144-token window the byte cap binds first.
- **The catalog is never cut.** Its cut order is oldest turns, then
  memory, then refusal; the compact order (turns, Upcoming days,
  memory) and the `dropped` vocabulary are unchanged. A window at or
  under the reply reserve refuses every send, truthfully — no clamping.
- **Ingestion is expected to take minutes, and is paid in advance.**
  The first-token deadline grows with the encoded request (one second
  per 64 bytes over the flat floor — a whole-catalog turn measured
  3 m 45 s on a 2-bit 27B laptop), so a big first turn is never cut
  down mid-ingestion. The cache warmer (`cacheWarmerProvider`) sends
  the shared prefix of every turn — profile and catalog, one reply
  token, `assembleWarmup` — through the recorder whenever the active
  local endpoint is ready and the prefix changed (debounced, never
  while a turn runs, cancelled when one starts; a finished catalog turn
  counts as the warm), so the endpoint's prompt cache holds the prefix
  before the person asks and the real turn pays only for its tail. A
  warm is a recorded call like any other: it carries the catalog, so it
  goes through ADR 0010's one gate and into the log. The clients show
  `warming up`, with a percentage estimated from the machine's measured
  ingestion rate; the CLI never warms. A failed warm is retried only
  when something changes, and never reaches a cloud provider by
  construction (the warmer only runs for a `local` endpoint, and the
  policy would withhold a catalog anyway).
- Accepted limit: two identical titles in identically-titled containers
  render indistinguishably — ids stay out of the prompt.

## Amendment (2026-09-04, #62, ADR [0024](0024-provider-choice-is-an-order-resolved-at-send.md))

"The active provider" is now the first entry of a preference order that
can answer, resolved at the top of `send` and `propose` — before this
function is called, because the shape, the budget, the effort and the
provenance all belong to whichever provider answers, not to the one the
person named first. Assembly is unchanged and still knows nothing of
providers: the caller maps the *answering* provider's tag to a shape and
hands in its window. The cache warmer follows the same resolution.

## Amendment (2026-09-05, #14, ADR [0027](0027-the-profile-is-a-reviewed-file-compiled-into-the-clients.md))

The profile slot is filled. `defaultProfile` is gone; `assembleContext`,
`assembleProposal` and `assembleWarmup` take `assistantProfile` —
`profile/system-prompt.md` compiled into core — through
`assistantProfileProvider`, one source for the three readers. The
signature did not change, as promised above; the warm key now includes
the profile, so a revised profile re-warms. #31 was absorbed by #14.
