# 3. Event ids hash the exact line bytes

Date: 2026-08-23 · Status: accepted · Issue: #12 · Spec: [event-log-v0](../archive/event-log-v0.md)

## Context

The event log needs content-hash ids that a future system — any language,
decades out — can verify. The first design canonicalized JSON (RFC 8785
JCS) and hashed the canonical form with the id embedded in the line.
Research into prior art (git, Perkeep, Certificate Transparency, tlog,
Nostr, Matrix; Schneier–Kelsey and successors on audit logs; the Dart SDK
source for its I/O and JSON guarantees) changed the design.

## Decision

1. **The id is the SHA-256 of the exact bytes of the line as written**,
   not stored inside it — the git/Perkeep/CT model. Verification is
   `shasum -a 256`; there is no canonicalization spec to implement, ever.
   Rejected: RFC 8785 JCS (informational only, no Dart implementation,
   pins ECMAScript number formatting that Dart's `toString` diverges
   from), Matrix-style content hashes (pull a second spec — redaction —
   into hashing), Nostr positional arrays (freeze the field list).
2. **Ids are Perkeep blobrefs** (`sha256-<hex>`): the algorithm is named
   in the reference, so a hash migration never rewrites stored refs, and
   v0 ids are already valid ids for the planned Perkeep-shaped v0.2 store.
3. **Tamper evidence = prev-hash chain + anchored HEAD.** A chain alone
   cannot expose tail truncation (Ma–Tsudik on Schneier–Kelsey); CT and
   tlog anchor their heads with signed checkpoints, git with refs. v0
   anchors with a `HEAD` file renamed atomically under the append lock —
   the keyless minimum. Signed, off-machine checkpoints are #16/#15.
4. **Write and lock discipline follows what Dart actually provides**
   (verified in the SDK source, not the docs): `flush()` is `fsync`;
   append mode seeks at open (there is no `O_APPEND`), so files are
   positioned under the lock; the only lock is `fcntl` record locking,
   whose locks die when any descriptor to the file closes — so one
   dedicated `LOCK` file gets one long-lived handle per instance, plus an
   in-process gate because `fcntl` locks are per-process.
5. **Recovery is point-in-time and non-destructive** (LevelDB, RocksDB,
   SQLite WAL): a torn tail stops reads and appends loudly; the sanctioned
   repair truncates only bytes that never became an event, and zero-length
   day files (an interrupted first write) are ignored outright.
6. **HEAD is best-effort durable, and recovery compensates.** Lines are
   fsynced; the HEAD rename is not (Dart cannot fsync a directory), so a
   power loss can leave HEAD several events behind. Openers accept a HEAD
   that is a stale but truthful prefix of the verified chain and roll it
   forward; anything else — including a lost HEAD — stays loud, because a
   silently rebuilt anchor would erase truncation detection.

## Consequences

- Any future reader verifies the archive with a shell; nothing about sai,
  Dart or JSON key order needs to survive for verification to work.
- Lines are not self-identifying; ids are derived on read (µs per line)
  or looked up in rebuildable indexes.
- A crash can cost the most recent events (macOS fsync does not reach the
  platter; `F_FULLFSYNC` needs an fd Dart does not expose). Detected at
  the next open, never silent. Revisit via FFI if it ever bites.
- An attacker who can rewrite both the day files and HEAD is not
  detected: v0 is tamper-evident, not tamper-proof, until #16 signs
  checkpoints and #15 replicates them off-machine.
