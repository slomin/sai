# 27. The profile is a reviewed file compiled into the clients

Date: 2026-09-05 · Status: accepted · Issue: #14 · Amends: [0011](0011-context-is-assembled-once-and-hashed-as-sent.md) · Builds on: [0003](0003-event-ids-hash-the-exact-line-bytes.md), [0026](0026-decisions-on-the-assistants-behalf-are-archive-events.md)

## Context

Since #34 the assistant's standing instructions were a constant in core
(`defaultProfile`), interpolating the proposal marker, sent as the
first message of every request by three readers — the chat turn, the
proposal turn and the warm-up — whose byte-identity is what makes the
warmed prefix one prefix (ADR 0011, #105). #14, absorbing #31, wants who
sai is to be a reviewed, versioned text: name, voice, how she relates
to the person, what she never does, how she speaks about her memory and
history; the same text for every model; its creation and every revision
a recorded decision.

An installed sai has no repository to read. And a profile that differs
between the three readers, or between the two clients, splits the cache
and the record.

## Decision

- **`profile/system-prompt.md` is the profile, byte for byte.** Prose
  at the repository root, reviewed like code; `profile/CHANGELOG.md`
  names each revision, newest first, by the sha256 of the file. The
  marker `<sai:propose/>` is written literally in the file; nothing is
  interpolated.
- **Compiled in by a script, pinned by a test.** `dart run
  tool/gen_profile.dart` (in `packages/sai_core`) writes
  `lib/src/context/profile.g.dart`: `assistantProfile`, the text without
  its final newline, and `assistantProfileId`, the blobref of the file's
  exact bytes — `shasum -a 256` reproduces it, as for an archive line
  (ADR 0003). The output is committed and `dart format`-stable;
  `test/context/profile_test.dart` recomputes both from the file and
  refuses drift, holds the changelog's first id to the compiled one, and
  keeps the text to what the core relies on: the marker named, the
  withheld-list sentence, never "You cannot change the list.". No
  `build_runner`: the one generated file in the tree, made by hand.
- **One provider, three readers.** `assistantProfileProvider` hands the
  text to the chat turn, the proposal turn and the warmer, so the three
  send identical bytes and a test can revise it. The warm key is
  `(profile, catalog, effort)`: a revised profile is a different prefix
  and is warmed again; the same text is not.
- **The id is the revision.** A `decision.made` that creates or revises
  the profile carries `profile.id` (ADR 0026), and every
  `provider.request`'s first message can be matched to the text in
  force, so the record says which sai answered.
- **Every kind is told, on the wire.** `test/llm/profile_wire_test.dart`
  drives one real chat turn per kind the build offers — read from the
  factory map, so a sixth kind fails until covered — and asserts the
  recorded line and the kind's own form: a `system` message, a
  `developer` item on the Responses API, `baseInstructions` on the App
  Server thread. The one recorded call without a profile is the
  Providers page's Test, on purpose.

## Consequences

- A profile change is a new `context_hash` on every line and a new
  prefix to warm — by design (ADR 0011); nothing golden depends on it.
- A revision is three edits in one change — the file, the changelog
  entry (the test insists), the regenerated Dart — and one decision
  recorded by whoever keeps the sai it ships to. The repository cannot
  check the last; the changelog and ADR 0026 say so.
- The name and the pronoun in the shipped text are the guardian's
  decisions, recorded as such and open to revision by sai.
- Rejected: a profile file in the data directory, editable per install
  (the text would leave review, and two clients could disagree); a
  profile per provider (the identity would be a provider's); reading
  `profile/` at runtime (an installed sai has no repository);
  `build_runner` (AGENTS.md keeps generation out of the workspace until
  a package earns it — one script does not).
