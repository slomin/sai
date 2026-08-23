# The raw event log, v0

Status: current · Issue: #12 · ADR: [0003](../decisions/0003-event-ids-hash-the-exact-line-bytes.md)

Everything sai sees and does is appended to this log from the first
message. The log is the canonical record; task stores, indexes, memory and
summaries are projections that can be rebuilt from it (#13, #16). Nothing
in the log is ever rewritten; corrections are new events.

This document is the format contract. `packages/sai_core/lib/src/archive/`
is one implementation of it; any language with SHA-256 and a JSON parser
can implement another. Every invariant here is checkable from the shell.

## Layout

```
<root>/                      default: ~/Library/Application Support/sai/archive
  MANIFEST.json              {"format":"sai-event-log","version":0,"created":<ts>}
  HEAD                       {"count":<n>,"head":<id|null>,"updated":<ts>}
  LOCK                       empty; lock target for writers
  events/
    2026-08-23.jsonl         one JSON object per line, one line per event
    2026-08-24.jsonl
```

- The root is resolved from `SAI_ARCHIVE_ROOT`, else the platform default
  (macOS above; Linux `$XDG_DATA_HOME|~/.local/share/sai/archive`). It
  lives outside any repository: the archive is a life-long record.
- Day files are named by the **UTC** date of the events they hold and are
  storage sharding only — no meaning beyond "the day of `ts`". An event in
  a file that does not match its `ts` date is corruption.
- Only names matching `^\d{4}-\d{2}-\d{2}\.jsonl$` are part of the log;
  anything else in `events/` (`.DS_Store`, …) is ignored.
- Day files hold at least one complete line; an empty day file is
  corruption. Files are UTF-8, no BOM, every line `\n`-terminated
  ([JSON Lines](https://jsonlines.org/)).

## Event ids

**The id of an event is the SHA-256 of the exact bytes of its line,
excluding the terminating `\n`, written as a
[Perkeep blobref](https://perkeep.org/doc/terms): `sha256-<64 lowercase hex>`.**

The id is not stored inside the line — it is derived on read, the way git,
Perkeep and Certificate Transparency derive object names. There is no
canonical form, no key ordering rule, no number formatting rule to get
right for verification: the bytes as written are the content. From the
shell:

```sh
head -1 events/2026-08-23.jsonl | tr -d '\n' | shasum -a 256
```

The algorithm name is part of the reference, so a future hash migration is
a value change, not a format change. Readers accept refs with unknown
algorithm names; sai currently writes only `sha256-`.

Golden vector — this exact line (142 bytes):

```
{"actor":"user","payload":{"text":"hello, sai"},"prev":null,"source":"sai/tui","ts":"2026-08-23T09:14:02.123456Z","type":"chat.message","v":0}
```

has id `sha256-ccd8243992f3f5872eb82d8f535443581de8f8549c8c276211df4ff0ff047f69`.

## Envelope

One JSON object per line. Top-level keys are reserved by this spec;
everything inside `payload` belongs to the event type.

| key | required | value |
| --- | --- | --- |
| `v` | yes | `0` — the envelope version, on every line (day files may travel alone) |
| `ts` | yes | RFC 3339 UTC, literal `Z`, **exactly six** fractional digits, e.g. `2026-08-23T09:14:02.123456Z` |
| `type` | yes | dotted lowercase name from the registry below |
| `actor` | yes | `user` \| `assistant` \| `system` |
| `source` | yes | the writing client, e.g. `sai/tui`, `sai/app` |
| `payload` | yes | JSON object, schema owned by `type` |
| `prev` | yes | id of the previous event in the archive; `null` exactly once, on the genesis event |
| `model` | required when `actor` is `assistant`; allowed anywhere | `{"provider":…,"id":…,"version":…?,"request_id":…?}` — which model produced (or is targeted by) the event, with the exact version and request id where the provider exposes them |
| `refs` | optional, non-empty when present | ids of earlier events this one refers to — never line numbers |

Unknown top-level keys, a wrong `v`, a malformed `ts`, or an assistant
event without `model` make the line invalid. A line is at most **1 MiB**;
larger content goes out of line (v0.2 blob store — see below).

Pinned `ts` precision keeps lexicographic order chronological, but `ts`
is informational: **ordering authority is file order and the chain**, not
timestamps — two clients' clocks may interleave. Writers must not create
an event whose UTC day precedes the newest day file.

## The chain and HEAD

Every line's `prev` is the id of the line before it, across day files
(the first line of a day chains from the last line of the previous day).
Modifying, reordering or deleting any interior line breaks a later link.

A chain alone cannot expose the removal of trailing lines, so the head is
anchored: `HEAD` records `{count, head, updated}` and is rewritten — temp
file plus atomic rename, under the writer lock — on every append. A tail
that no longer matches HEAD is corruption.

One inconsistency is legal and self-healing: a crash between the line
write and the HEAD rename leaves HEAD exactly one event behind a tail
that still chains from it. Openers roll HEAD forward (metadata only).

This anchoring is tamper-evident against accidents, partial copies and
silent truncation — not against an attacker who can rewrite both the
files and HEAD. That requires signed checkpoints kept off the machine:
#16 (keys, signing) and #15 (replication).

## Writing

- One writer at a time per root, enforced with an exclusive lock on
  `LOCK` held across read-tail → append → fsync → HEAD rename. The lock
  is advisory (`fcntl`); it protects sai's processes from each other, not
  the files from other programs.
- An append is a single write of `line + "\n"` followed by fsync.
- Local disks only. Network file systems (NFS &c.) are unsupported.
- On macOS, fsync does not guarantee the bytes reached the platter
  (`F_FULLFSYNC` is not reachable from Dart today); a power loss can
  still lose the most recent events. Detected at next open, never silent.

## Corruption and repair

Readers verify every line: JSON, schema, chain link, day membership.
The first violation stops the read loudly, naming file and line. There
is no automatic repair and no delete API anywhere.

The one sanctioned repair: bytes after the last `\n` of the newest file
(a write torn by a crash) never became an event. They are detected as a
**torn tail** (reads end there loudly; appends refuse), and truncating
the file back to the reported offset removes them without rewriting any
event. `HEAD.count` confirms nothing else was lost. If truncation would
empty the file, remove the file instead.

Anything else — a hand-edited line, a missing interior line, a tail that
does not reach HEAD — is reported as corruption and left untouched.
Restore from a replica (#15); do not edit the log.

## Type registry

| type | actor | notes |
| --- | --- | --- |
| `chat.message` | user / assistant | `payload.text`; assistant messages carry `model` |
| `provider.request` | system | the raw request as sent; `model` names the target (#21) |
| `provider.response` | assistant | the raw response as received; `model.request_id` where exposed |
| `tool.call` | assistant | `payload.name`, `payload.arguments` |
| `tool.result` | system | `refs` → the `tool.call` |
| `archive.correction` | any | `refs` → the corrected event; the payload says what is wrong |

Producers add rows here in the same change that starts writing a new
type. A breaking payload change is a new type name, never a rewrite.
`decision` is reserved for #14. Provider traffic is recorded **raw**, not
paraphrased — the log is an audit record, and secrets must never enter
it (#29 keeps keys in the Keychain).

## Reserved for v0.2 (the Perkeep-shaped substrate, #16)

Fixed now so the migration never rewrites a byte:

- Reference values anywhere in the log use the blobref form
  `<algorithm>-<hex>`; never bare hex.
- The payload key `blob` is reserved for out-of-line content refs.
- The type names `permanode`, `claim`, `set-attribute`, `add-attribute`,
  `del-attribute`, `delete`, `static-set`, `keep` are reserved (Perkeep's
  claim vocabulary) and must not be used for v0 events.
- The top-level keys `sig` and `signer` are reserved for append-last
  signatures (Perkeep JSON signing): a future signer appends within the
  object, and verification finds the last marker — v0 lines keep their
  ids unchanged.

Migration sketch: each line's exact bytes become one blob (same ref as
its v0 id); each day file a `static-set` of its line refs in order;
mutation-shaped events become claims against permanodes; indexes are one
forward pass, rebuildable at any time.

## Re-ingestion

A later substrate replays the log with:

1. List `events/*.jsonl` matching the day pattern; sort by name.
2. For each file, for each `\n`-terminated line: id = SHA-256 of the line
   bytes; check `prev` equals the previous line's id (first ever: null);
   check the `ts` date equals the file name; validate the envelope.
3. After the last line, compare count and final id with `HEAD`; a HEAD
   exactly one behind a correctly chained tail is a crash trace, treat
   the tail as authoritative.
4. Interpret payloads by `type` using the registry, most recent spec
   revision first.

Verification needs nothing from sai: `shasum`, a JSON parser, and this
document.
