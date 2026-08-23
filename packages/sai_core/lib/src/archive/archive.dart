import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'blobref.dart';
import 'event.dart';
import 'store.dart';

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
      'repair by truncating the file to that offset, then retry';
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
    archive._store.ensureLayout(createdTs: formatTs(archive._clock()));
    await archive._store.withLock(() async => archive._reconcileHead());
    return archive;
  }

  /// Appends one event: seals [draft] onto the chain, writes its line with
  /// fsync, then advances HEAD. Returns the stored event with its id.
  Future<StoredEvent> append(EventDraft draft) => _store.withLock(() async {
    final tail = _tailState();
    final ts = (draft.ts ?? _clock()).toUtc();
    final day = formatTs(ts).substring(0, 10);
    final files = _store.dayFiles();
    if (files.isNotEmpty) {
      final newestDay = p.basenameWithoutExtension(files.last.path);
      if (day.compareTo(newestDay) < 0) {
        throw ArgumentError(
          'event ts falls on $day, before the newest day file $newestDay: '
          'day files are chain-ordered',
        );
      }
    }
    final event = Event.seal(draft, prev: tail.head, ts: ts);
    final bytes = utf8.encode(event.encode());
    final id = BlobRef.sha256OfBytes(bytes);
    _store.appendLine(_store.dayFile(day), bytes);
    _store.writeHead(
      HeadRecord(count: tail.count + 1, head: id, updated: formatTs(_clock())),
    );
    return StoredEvent(id: id, event: event);
  });

  /// All events, oldest first, verifying as it goes: every line's id links
  /// the next line's `prev`, every event sits in its own UTC day's file.
  /// Throws [ArchiveCorruptionError] on the first violation and
  /// [TornTailError] after the last complete line when the newest file was
  /// torn mid-write.
  Stream<StoredEvent> events() async* {
    BlobRef? prev;
    final files = _store.dayFiles();
    for (final (index, file) in files.indexed) {
      final day = p.basenameWithoutExtension(file.path);
      final (lines, torn) = _store.readDayLines(file);
      if (lines.isEmpty && torn == null) {
        throw ArchiveCorruptionError(
          file: file.path,
          reason: 'empty day file: day files hold at least one event',
        );
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
        if (!event.tsText.startsWith(day)) {
          throw ArchiveCorruptionError(
            file: file.path,
            line: i + 1,
            reason:
                'event at ${event.tsText} sits in the wrong day file ($day)',
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
  /// match the recomputed count and head exactly. This is what a restore
  /// drill runs against a replica.
  Future<ArchiveReport> verify() async {
    var count = 0;
    BlobRef? last;
    await for (final stored in events()) {
      count++;
      last = stored.id;
    }
    final head = _store.readHead();
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

  /// The chain position to append after, cross-checked against the newest
  /// file's tail. Caller holds the lock.
  HeadRecord _tailState() {
    final head = _store.readHead();
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
    final (lastLine, torn) = _store.readTail(file);
    if (torn != null) {
      throw TornTailError(file: file.path, offset: torn);
    }
    if (lastLine == null) {
      throw ArchiveCorruptionError(
        file: file.path,
        reason: 'empty day file: day files hold at least one event',
      );
    }
    final lastId = BlobRef.sha256OfBytes(utf8.encode(lastLine));
    if (head.head == lastId) {
      return head;
    }
    // A crash between line-fsync and HEAD-rename leaves HEAD exactly one
    // event behind a tail that still chains from it.
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
    throw ArchiveCorruptionError(
      file: _store.headFile.path,
      reason:
          'HEAD (${head.head}) matches neither the newest line ($lastId) '
          'nor its prev (${lastEvent.prev}); run verify() and restore from '
          'a replica if needed',
    );
  }

  /// Open-time reconciliation: persist a roll-forward if [_tailState] found
  /// one. Caller holds the lock.
  void _reconcileHead() {
    final HeadRecord tail;
    try {
      tail = _tailState();
    } on TornTailError {
      // Still readable up to the tear; append will refuse until the
      // documented repair, so there is nothing to roll forward yet.
      return;
    }
    final head = _store.readHead();
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
