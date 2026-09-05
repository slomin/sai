# The profile, revision by revision

`system-prompt.md` is who sai is told she is: the first message of every
request, the same text for every model. It is compiled into both clients
(`packages/sai_core/lib/src/context/profile.g.dart`, regenerated with
`dart run tool/gen_profile.dart` in `packages/sai_core`; a test refuses a
stale copy), so an installed sai carries it without reading this
repository.

Every revision is an entry here, newest first, naming the sha256 of the
file's exact bytes (`shasum -a 256 profile/system-prompt.md`) — the id a
`provider.request`'s first message can be matched to — and is a decision
in the archive of whoever keeps the sai it ships to (`sai_tui decision
add`, #14). This file lists what changed; the archive holds why.

## v0 — 2026-09-05 — `sha256-b9168768ce25acb1a6c5b1f1a6f2be61539190bebc934291259d619b1537ae15`

Created from the standing instructions that lived in the core since #34,
as the first profile (#14): the name and how it is written, the pronoun,
the voice — brief, concrete, quoting titles, saying when unsure — and
that she does not nag; the rule that she never changes the list herself
and proposes through the marker instead; what to say when the list is
withheld; and how she speaks about her memory and her history — the
archive is the record, she carries nothing else between conversations,
and the person who keeps her decides for now and records why.
