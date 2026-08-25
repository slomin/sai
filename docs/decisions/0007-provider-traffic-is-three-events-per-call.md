# 7. Provider traffic is three events per call

Date: 2026-08-24 · Status: accepted · Issue: #21 · Spec: [event-log-v0](../archive/event-log-v0.md)

## Context

Every model call must land in the archive (#21): the request as sent,
what came back, and what it cost — for every call, including the ones
that fail (#30). Answers arrive as a stream of deltas, and the log
already reserved `provider.request` and `provider.response` with the
note "recorded raw, not paraphrased". The question was the granularity:
one line per delta, or one line per answer, and where usage goes.

## Decision

One call is **exactly three lines**, written by one recorder
(`packages/sai_core/lib/src/llm/recorder.dart`):

1. `provider.request` (actor `system`), appended **before** the provider
   is started, so a crash mid-call still leaves the request on record.
2. `provider.response` (actor `assistant`) with the assembled text and
   why it ended — or `provider.failure` (actor `system`) when there is
   no answer, carrying the typed failure and whatever partial text
   arrived.
3. `provider.usage` (actor `system`): finish, wall-clock duration,
   tokens and timings — always, so a failed call costs as visibly as a
   successful one.

The response, failure and usage lines carry `refs` to the request line;
`model` on all three names the target, and the response adds the
backend's version and request id where it exposes them.

Why not per-delta lines: an append is one locked, fsynced write measured
at ~3 ms (ADR [0004](0004-the-task-store-is-event-sourced.md)). A
five-hundred-token answer would be five hundred fsyncs and five hundred
lines to read back one paragraph — a tax on every reader forever, for a
level of detail nothing needs. What the user saw is the assembled text;
what the log records is the assembled text.

Why usage is its own line and not a field on the response: a failed
call has no response to hang it on, and #30 aggregates usage without
caring which shape the call ended in.

Why a cancelled call is a response, not a failure: its partial text is
what the assistant said and what the user read. Assistant speech has one
type; `finish: cancelled` says how it stopped.

## Consequences

- The recorder, not the provider, is the single request-assembly point
  — the privacy policy (#27) hooks there and nowhere else. Amendment
  (ADR [0010](0010-the-privacy-policy-is-a-switch-checked-in-the-recorder.md)):
  a call to a `cloud`-tagged provider is preceded by one
  `policy.decision` line; the three-line rule is unchanged for the call
  itself, and local calls carry no extra line.
- Text is bounded to half a line (`maxRecordedTextBytes`) and cut on a
  rune boundary with a `truncated` marker, so "raw" is qualified in
  exactly one documented way; a request that would not fit is refused
  before it is sent.
- A reader reconstructing a conversation joins request → response by
  `refs`; there is no per-delta timing in the log, only tokens per
  second where the backend reports it. Since #34 the conversation is
  also written in its own words — `chat.message` lines around the call
  (ADR 0011) — so the three provider lines remain the wire record and
  nothing more.
- Stored provider events pass through the task projection untouched
  (it counts foreign types and applies none), so the task store and
  the provider record share one chain.
