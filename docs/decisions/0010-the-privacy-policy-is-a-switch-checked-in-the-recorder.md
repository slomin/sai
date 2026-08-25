# 10. The privacy policy is a switch checked in the recorder

Date: 2026-08-25 · Status: accepted · Issue: #27 · Schema: [event-log-v0](../archive/event-log-v0.md), [settings-v0](../settings/settings-v0.md)

## Context

The task list and the archive are personal data. Every provider carries
a `local` or `cloud` tag (`LlmPrivacy`, #21), and the cloud kinds
(#24–#26) are next. Before any of them exists there must be a rule for
what may leave the machine, a place where the rule is applied, and a
record of it having been applied — otherwise the first cloud provider
ships with the list in every request and no one can tell afterwards.

v0.1 is deliberately coarse: the ticket rules out field-level redaction
and per-task sensitivity, and the fallback order (#62) needs only a
yes/no per provider.

## Decision

- **One switch.** `share_tasks_with_cloud` in `settings.json`, off by
  default. A `cloud` provider sees the task context only while it is
  on; a `local` provider always does. There is no per-provider switch:
  the tag is the only input. The tag is where the inference runs, which
  a kind may know (the cloud kinds, #24–#26) and an `openai_compatible`
  endpoint cannot — so that kind takes it from the endpoint's host by
  default (loopback, private and LAN names are `local`, anything else
  is `cloud`: a `/v1` on a public name is as likely a hosted service as
  a home server) and from an explicit `privacy` key when the user knows
  better. The `fake` takes the key too, so the policy can be exercised
  in both clients before a cloud backend exists.
- **One check, in the recorder.** ADR
  [0007](0007-provider-traffic-is-three-events-per-call.md) made
  `LlmRecorder` the single point where requests are assembled; the
  policy lives there (`PrivacyPolicy.decide`) and nowhere else. The
  policy is read when a call starts, so a flipped switch governs the
  next request without rebuilding anything under a running one.
- **Task context travels apart from the messages.**
  `LlmRequest.taskContext` is the list as the caller wants the model to
  see it; the recorder turns it into a `system` message (after the
  caller's own system messages) when it may be sent, and drops it when
  it may not. The policy never reads prose to find personal data, and
  a provider never sees the field.
- **The decision is an archive event, for cloud calls only.** A call to
  a `cloud` provider is preceded by one `policy.decision` line
  (`privacy`, `share_tasks`, `task_context` ∈ `none` | `sent` |
  `withheld`); the `provider.request` that follows refers to it and
  records the messages as sent, so withheld context enters neither the
  wire nor the log. A local call stays exactly three lines: nothing is
  at stake and nothing was decided.
- **Selecting a cloud provider warns, never refuses.** Both clients show
  the tag on the active provider at all times, append `· tasks withheld`
  to the status line while the switch is off, and say so on selection.
  The assistant then operates without the list.

## Consequences

- #34 fills `taskContext` (through `assembleContext`, ADR 0011); it
  never builds a system message with the list itself, or the policy
  could not withhold it.
- #62 asks the same policy whether a cloud provider is *eligible*; a
  cloud provider with the switch off is skipped rather than fed an
  empty context, and that skip is its own decision event.
- Redaction, per-task flags or a per-provider allowance would replace
  `taskContext` with something richer and `decide` with something
  finer; the check's location and the event's place in the chain would
  not move.
- Rejected: a decision line on every call (four lines per local call,
  for a decision with one possible outcome); a per-provider switch (the
  tag already says what matters, and two switches disagree); refusing
  the selection (the user asked for that provider; the policy's job is
  to bound what it sees, not to second-guess the choice).
