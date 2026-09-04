# 24. Provider choice is an order, resolved at send

Date: 2026-09-04 · Status: accepted · Issue: #62 · Schema: [settings-v0](../settings/settings-v0.md), [event-log-v0](../archive/event-log-v0.md) · Amends: [0010](0010-the-privacy-policy-is-a-switch-checked-in-the-recorder.md), [0011](0011-context-is-assembled-once-and-hashed-as-sent.md)

## Context

Until now sai talked to exactly one provider: `settings.llm` named it,
`activeLlmProvider` looked it up, and everything downstream — the status
line, the connection light, the cache warmer, the chat's shape and budget
— read that one value. When that backend was asleep (the LAN box, LM
Studio not launched) the assistant was dead until someone opened Settings
and switched by hand.

The obvious fix — try the next one — has three traps. Trying it *after* a
failed chat means a failed turn, a cancelled stream and a second bill; the
health has to be known before the call. Choosing inside the recorder is
too late: since #105 the context shape (compact or catalog), the probed
token budget and the turn's provenance all depend on which provider
answers, and the recorder is where the request is already assembled (ADR
[0007](0007-provider-traffic-is-three-events-per-call.md)). And falling
through to a cloud provider is not a neutral act: it is exactly the case
#27's switch exists for.

## Decision

- **The selection is an ordered list.** `settings.llm` stays the string
  head — the first choice — and a new `llm_fallback` holds the ids tried
  behind it. Not one JSON array, because `Settings.decode` refuses a
  non-string `llm` and the store *quarantines* the file it cannot read:
  an array would make every older binary lose the person's providers,
  workspace and privacy switch on first sight. A one-entry order writes
  the file an older sai wrote, byte for byte, and an older sai reading a
  longer one selects the head and carries the tail through untouched
  (`extra`).
- **Using a provider sets the order's first entry, never the whole
  order.** An id already in the order moves to the front; a new one takes
  the head's place and the arranged tail stands. The order therefore
  grows only where a person arranges it — the Providers page's handles and
  arrows, `sai_tui provider order` — and never out of what was used
  before. The rejected alternative was "promote and keep", which quietly
  builds a fallback chain from history: a request meant for one backend
  is then answered by one chosen weeks ago.
- **Resolution happens at send entry, before assembly.** `resolveLlm`
  (`llm/fallback.dart`) is pure: order × registry × misconfiguration ×
  credential × privacy × health, in that ladder, answering with the first
  entry that can take the request and the list of what it passed over.
  `activeLlmProvider` *is* that answer; the chat reads the resolution once
  at the top of `send` and `propose` and threads it through, so the shape,
  the budget, the effort and the provenance all belong to the provider
  that actually answers.
- **Health is what the last probe filed, never a call.** sai is not a
  supervisor: it never starts, restarts or reconfigures a backend. The
  connection notifier walks the eligible entries from the top on its
  timer, files each answer in a retained per-id map and **stops at the
  first that answers** — so a healthy local box costs no cloud traffic,
  and the head is asked every time, which is how a recovered first choice
  is picked up again with no restart. `unknown` health is eligible: it
  means "not asked yet" or "cannot be asked" (the fake), and a send never
  waits for a probe.
- **The privacy switch is an eligibility gate.** A `cloud`-tagged provider
  is passed over entirely while "allow cloud providers to see my tasks"
  is off — first choice or not — so a chat never goes to a cloud provider
  under that switch. With nothing else in the order the send is refused,
  naming every entry and its reason. This supersedes ADR 0010's
  "selecting a cloud provider warns, never refuses": the warning stays,
  the answering does not.
- **A fall-through is on the record.** A call that did not go to the first
  choice is preceded by one `policy.fallback` line — the first choice,
  what answered, and every entry passed over with its reason — before the
  `policy.decision` line, if any; the request's `refs` name both. A call
  whose caller named the provider itself (the Providers page's Test) has
  none: it is testing that provider, not the order.

## Consequences

- Both clients show the answering provider and, when it is not the first
  choice, what was passed over (`local · lan unreachable`) — one string in
  `llm/status.dart`, so neither client composes it. When nothing can
  answer, the line describes the first choice in the words it always
  used; the complete list belongs to the refusal and to the Providers
  page, which shows the order's verdict per row.
- `taskContextWithheld` stops being reachable from chat: a cloud provider
  now answers only with sharing on, and then it sees the compact lists.
  The recorder's withholding stays — it is the guarantee ADR 0010 rests
  on, and other callers still go through it.
- A missing key skips like an unreachable endpoint, so an order routes
  around a provider whose key was never entered instead of making a call
  that is certain to fail.
- The cache warmer follows the resolution with no logic of its own; a
  fall-through is a cold cache for the new provider, which its per-id
  bookkeeping already handles.
- Rejected: retrying a failed chat on the next provider (a failed turn and
  a second bill, and the ticket rules it out); probing every entry on the
  timer (a cloud model-list request a minute for a provider a healthy
  local one makes moot); a per-request override (#62 is about a standing
  preference, not a per-turn choice).
