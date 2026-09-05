import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'blobref.dart';
import 'event.dart';
import 'store.dart';

part 'replicate.dart';

/// An event as it exists in the log: the envelope plus the id derived from
/// the exact bytes of its line.
final class StoredEvent {
  const StoredEvent({required this.id, required this.event});

  final BlobRef id;
  final Event event;
}

/// The result of a full integrity pass. `count` and `head` are recomputed
/// from the files and, by the time this exists, proven equal to HEAD.
final class ArchiveReport {
  const ArchiveReport({required this.count, required this.head});

  final int count;
  final BlobRef? head;

  @override
  String toString() => 'ArchiveReport(count: $count, head: $head)';
}

/// The log refuses to lie: any line that is not exactly what was written —
/// bad JSON, a schema violation, a broken chain link, a misfiled day, a
/// mismatched HEAD — stops the operation with this error. Nothing repairs
/// automatically; corrections are new events.
final class ArchiveCorruptionError implements Exception {
  const ArchiveCorruptionError({this.file, this.line, required this.reason});

  /// Path of the offending file, when one is identifiable.
  final String? file;

  /// 1-based line number inside [file], when one is identifiable.
  final int? line;

  final String reason;

  @override
  String toString() =>
      'ArchiveCorruptionError: $reason'
      '${file == null ? '' : ' ($file${line == null ? '' : ':$line'})'}';
}

/// Bytes at the end of the newest day file that never became an event —
/// the trace of a write interrupted mid-line. Detected, never repaired
/// silently: truncate the file to [offset] (those bytes are not an event,
/// so removing them rewrites nothing) and the log carries on.
final class TornTailError implements Exception {
  const TornTailError({required this.file, required this.offset});

  final String file;

  /// Byte offset where the torn bytes start.
  final int offset;

  @override
  String toString() =>
      'TornTailError: $file has a torn tail at byte $offset; '
      'repair by truncating the file to that offset (a file truncated to '
      'zero bytes is ignored), then retry';
}

/// The append-only event log. `append` and read-only iteration — there is no
/// update and no delete, here or anywhere below.
///
/// Format contract: `docs/archive/event-log-v0.md`. Two local processes may
/// share one root (the store's lock discipline serializes them); network
/// file systems are unsupported.
final class Archive {
  Archive._(this._store, this._clock);

  final ArchiveStore _store;
  final DateTime Function() _clock;
  var _appended = 0;

  /// How many events this instance has appended since it opened. Every
  /// writer in a process shares one instance, so against the `HEAD` count
  /// this tells the process's own lines from another writer's (#118):
  /// read it right before [head] — both are synchronous, and [append]
  /// advances `HEAD` and this counter in one synchronous step.
  int get appended => _appended;

  /// Opens (creating if needed) the archive at [root].
  ///
  /// Reconciles HEAD with the file tail: a HEAD exactly one event behind a
  /// correctly chained tail is the trace of a crash between line-fsync and
  /// HEAD-rename, and is rolled forward — the only self-healing case, and
  /// it touches metadata only. Anything else inconsistent throws
  /// [ArchiveCorruptionError].
  static Future<Archive> open(
    Directory root, {
    DateTime Function()? clock,
  }) async {
    final archive = Archive._(ArchiveStore(root), clock ?? DateTime.timestamp);
    archive._store.ensureRoot();
    await archive._store.withLock(() async {
      try {
        archive._store.ensureState(createdTs: formatTs(archive._clock()));
      } on FormatException catch (e) {
        throw ArchiveCorruptionError(
          file: archive._store.manifestFile.path,
          reason: e.message,
        );
      }
      await archive._reconcileHead();
    });
    return archive;
  }

  /// Appends one event: seals [draft] onto the chain, runs the optional
  /// synchronous [validate] callback against that final envelope and id,
  /// writes its line with fsync, then advances HEAD. A validation failure
  /// touches neither the JSONL files nor HEAD.
  Future<StoredEvent> append(
    EventDraft draft, {
    void Function(StoredEvent stored)? validate,
  }) => _store.withLock(() async {
    final tail = await _tailState();
    final ts = (draft.ts ?? _clock()).toUtc();
    final event = Event.seal(draft, prev: tail.head, ts: ts);
    // File under the event's UTC day — or the newest existing day when the
    // clock stepped backwards across midnight (NTP, suspend) or the draft
    // is backdated: day files stay chain-ordered, the log never goes
    // write-dead, and ts stays truthful. Readers allow event day ≤ file day.
    var day = event.tsText.substring(0, 10);
    final files = _store.dayFiles();
    if (files.isNotEmpty) {
      final newestDay = p.basenameWithoutExtension(files.last.path);
      if (day.compareTo(newestDay) < 0) {
        day = newestDay;
      }
    }
    final bytes = utf8.encode(event.encode());
    final id = BlobRef.sha256OfBytes(bytes);
    final stored = StoredEvent(id: id, event: event);
    validate?.call(stored);
    _store.appendLine(_store.dayFile(day), bytes);
    _store.writeHead(
      HeadRecord(count: tail.count + 1, head: id, updated: formatTs(_clock())),
    );
    _appended++;
    return stored;
  });

  /// All events, oldest first, verifying as it goes: every line's id links
  /// the next line's `prev`, and no event is newer than its file's UTC day.
  /// Throws [ArchiveCorruptionError] on the first violation and
  /// [TornTailError] after the last complete line when the newest file was
  /// torn mid-write.
  ///
  /// Lock-free: a read that overlaps an in-flight append may transiently
  /// see it as a torn tail — re-read before acting on a tear reported here.
  /// [verify] takes the writer lock and cannot misreport.
  Stream<StoredEvent> events() async* {
    BlobRef? prev;
    final files = _store.dayFiles();
    for (final (index, file) in files.indexed) {
      final day = p.basenameWithoutExtension(file.path);
      final List<String> lines;
      final int? torn;
      try {
        (lines, torn) = _store.readDayLines(file);
      } on FormatException catch (e) {
        throw ArchiveCorruptionError(file: file.path, reason: e.message);
      }
      for (final (i, line) in lines.indexed) {
        final id = BlobRef.sha256OfBytes(utf8.encode(line));
        final Event event;
        try {
          event = Event.decodeLine(line);
        } on FormatException catch (e) {
          throw ArchiveCorruptionError(
            file: file.path,
            line: i + 1,
            reason: e.message,
          );
        }
        if (event.prev != prev) {
          throw ArchiveCorruptionError(
            file: file.path,
            line: i + 1,
            reason: 'chain broken: prev is ${event.prev}, expected $prev',
          );
        }
        if (event.tsText.substring(0, 10).compareTo(day) > 0) {
          throw ArchiveCorruptionError(
            file: file.path,
            line: i + 1,
            reason:
                'event at ${event.tsText} is newer than its day file ($day)',
          );
        }
        yield StoredEvent(id: id, event: event);
        prev = id;
      }
      if (torn != null) {
        if (index != files.length - 1) {
          throw ArchiveCorruptionError(
            file: file.path,
            line: lines.length + 1,
            reason: 'torn bytes inside a non-final day file',
          );
        }
        throw TornTailError(file: file.path, offset: torn);
      }
    }
  }

  /// Full integrity pass: walks [events] end to end, then requires HEAD to
  /// match the recomputed count and head exactly. Runs under the writer
  /// lock so a concurrent append cannot make a healthy archive look
  /// corrupt. This is what a restore drill runs against a replica.
  Future<ArchiveReport> verify() => _store.withLock(_walkAndCheckHead);

  /// [verify]'s body, for a caller that already holds the lock.
  Future<ArchiveReport> _walkAndCheckHead() async {
    var count = 0;
    BlobRef? last;
    await for (final stored in events()) {
      count++;
      last = stored.id;
    }
    final head = _readHead();
    if (head.count != count || head.head != last) {
      throw ArchiveCorruptionError(
        file: _store.headFile.path,
        reason:
            'HEAD records count ${head.count} head ${head.head}, '
            'files hold count $count head $last',
      );
    }
    return ArchiveReport(count: count, head: last);
  }

  /// Copies this archive into [destination] so that it becomes — or stays
  /// — a replica (#15, ADR 0025): the manifest, every day file the
  /// replica lacks or that has grown since, and a byte-equal HEAD, then
  /// the full integrity walk against the replica in place. A replica is
  /// only ever behind its source: a destination holding another archive,
  /// or bytes this one does not, is refused with [ReplicaRefusedError]
  /// and nothing is written; one that is not there (an unmounted volume)
  /// is [ReplicaUnavailableError]. Runs under both locks — the replica's
  /// first, then this archive's — so a copy never catches a half-written
  /// line and appends wait only for the copy of one day's tail.
  Future<ReplicaReport> replicateTo(Directory destination) =>
      _replicateTo(destination);

  /// Puts a replica back (#15): copies the archive at [from] into [into]
  /// and runs the full integrity walk against the copy. [into] must be
  /// empty — absent, or holding no events — because restoring over a live
  /// log would rewrite it; a damaged root is moved aside first. [from] is
  /// read in place and never opened, so it gains no LOCK and its HEAD is
  /// never rewritten; a HEAD that is a truthful prefix of its chain is
  /// accepted and rolled forward in the copy. Refuses with
  /// [ReplicaRefusedError]; a replica that does not verify throws
  /// [ArchiveCorruptionError] or [TornTailError] before anything is
  /// written.
  static Future<ArchiveReport> restore({
    required Directory from,
    required Directory into,
    DateTime Function()? clock,
  }) => _restore(from: from, into: into, clock: clock ?? DateTime.timestamp);

  /// The `HEAD` record as it stands: how many events the log holds and the
  /// id of the newest. Read without the lock and without walking the
  /// files — a cheap "has the log grown?" probe for a process that shares
  /// the root with another writer (a count that moved means a [events]
  /// re-read, or a `TaskStore.reload`, will see more). Not a check:
  /// [verify] is the locked, recomputed read. The file is read before the
  /// first suspension point, so a caller that reads [appended] just
  /// before sees the two as one instant.
  Future<ArchiveReport> head() async {
    final head = _readHead();
    return ArchiveReport(count: head.count, head: head.head);
  }

  /// Bytes the day files hold — what the log costs on disk. Read without
  /// the lock and without walking a line: a figure for a settings
  /// screen, not a check.
  Future<int> byteSize() async {
    var total = 0;
    for (final file in _store.dayFiles()) {
      total += file.lengthSync();
    }
    return total;
  }

  /// Releases the archive's lock handle. Call at a quiet point (provider
  /// disposal, shutdown) — the next operation reopens it transparently.
  Future<void> close() => _store.close();

  /// [ArchiveStore.readHead], with damage surfaced as the documented
  /// [ArchiveCorruptionError] instead of a bare [FormatException].
  HeadRecord _readHead() {
    try {
      return _store.readHead();
    } on FormatException catch (e) {
      throw ArchiveCorruptionError(
        file: _store.headFile.path,
        reason:
            '${e.message}; restore HEAD from a replica — the day files '
            'themselves are untouched',
      );
    }
  }

  /// The chain position to append after, cross-checked against the newest
  /// file's tail. Caller holds the lock.
  Future<HeadRecord> _tailState() async {
    final head = _readHead();
    final files = _store.dayFiles();
    if (files.isEmpty) {
      if (head.count != 0 || head.head != null) {
        throw ArchiveCorruptionError(
          file: _store.headFile.path,
          reason: 'HEAD records ${head.count} events but no day files exist',
        );
      }
      return head;
    }
    final file = files.last;
    final String? lastLine;
    final int? torn;
    try {
      (lastLine, torn) = _store.readTail(file);
    } on FormatException catch (e) {
      throw ArchiveCorruptionError(file: file.path, reason: e.message);
    }
    if (torn != null) {
      throw TornTailError(file: file.path, offset: torn);
    }
    final lastId = BlobRef.sha256OfBytes(utf8.encode(lastLine!));
    if (head.head == lastId) {
      return head;
    }
    // The common crash trace: HEAD exactly one event behind a tail that
    // still chains from it (crash between line-fsync and HEAD-rename).
    final Event lastEvent;
    try {
      lastEvent = Event.decodeLine(lastLine);
    } on FormatException catch (e) {
      throw ArchiveCorruptionError(file: file.path, reason: e.message);
    }
    if (lastEvent.prev == head.head) {
      return HeadRecord(
        count: head.count + 1,
        head: lastId,
        updated: head.updated,
      );
    }
    // HEAD renames are not durably synced the way lines are, so a power
    // loss can leave HEAD several events behind. Recover iff HEAD is a
    // stale but truthful snapshot: its head id sits at its count position
    // in a chain that verifies end to end. Anything else stays loud.
    final ids = <BlobRef>[];
    await for (final stored in events()) {
      ids.add(stored.id);
    }
    final truthful =
        head.count > 0 &&
        head.count <= ids.length &&
        ids[head.count - 1] == head.head;
    if (truthful) {
      return HeadRecord(
        count: ids.length,
        head: ids.last,
        updated: head.updated,
      );
    }
    throw ArchiveCorruptionError(
      file: _store.headFile.path,
      reason:
          'HEAD (count ${head.count}, ${head.head}) is not a prefix of the '
          'chain (count ${ids.length}, tail $lastId): the anchor is lost or '
          'the tail was cut; restore from a replica',
    );
  }

  /// Open-time reconciliation: persist a roll-forward if [_tailState] found
  /// one. Caller holds the lock.
  Future<void> _reconcileHead() async {
    final HeadRecord tail;
    try {
      tail = await _tailState();
    } on TornTailError {
      // Still readable up to the tear; append will refuse until the
      // documented repair, so there is nothing to roll forward yet.
      return;
    }
    final head = _readHead();
    if (tail.count != head.count) {
      _store.writeHead(
        HeadRecord(
          count: tail.count,
          head: tail.head,
          updated: formatTs(_clock()),
        ),
      );
    }
  }
}
