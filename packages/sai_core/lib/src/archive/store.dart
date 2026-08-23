import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'blobref.dart';

/// The anchored head of the archive: how many events exist and the id of the
/// last one. Rewritten atomically (temp file + rename) on every append, under
/// the same lock as the append itself — the minimum viable anchor against
/// silent tail loss for a single user without signing keys.
final class HeadRecord {
  const HeadRecord({
    required this.count,
    required this.head,
    required this.updated,
  });

  final int count;
  final BlobRef? head;
  final String updated;

  Map<String, Object?> toJson() => {
    'count': count,
    'head': head?.toString(),
    'updated': updated,
  };

  static HeadRecord fromJson(Map<String, Object?> json) => HeadRecord(
    count: json['count'] as int,
    head: json['head'] == null ? null : BlobRef.parse(json['head'] as String),
    updated: json['updated'] as String,
  );
}

/// All file-system knowledge of the event log lives here: layout, the lock
/// discipline, appends, the HEAD file, and tail classification. No schema
/// knowledge — that is `event.dart`; no policy — that is `archive.dart`.
final class ArchiveStore {
  ArchiveStore(Directory root)
    : root = Directory(p.normalize(root.absolute.path));

  final Directory root;

  File get manifestFile => File(p.join(root.path, 'MANIFEST.json'));
  File get headFile => File(p.join(root.path, 'HEAD'));
  File get lockFile => File(p.join(root.path, 'LOCK'));
  Directory get eventsDir => Directory(p.join(root.path, 'events'));

  static final _dayFileForm = RegExp(r'^\d{4}-\d{2}-\d{2}\.jsonl$');

  /// One in-process gate per root path: Dart's file locks are fcntl locks,
  /// which are process-wide — two instances in one process would both
  /// "acquire" them. The OS lock below still guards other processes.
  static final _gates = <String, Future<void>>{};

  /// One long-lived handle per instance. fcntl drops every lock a process
  /// holds on a file when *any* descriptor to it closes, so this handle is
  /// opened once and never closed, and no other handle to LOCK is ever made.
  RandomAccessFile? _lockHandle;

  /// Creates the layout if missing; never resets an existing archive.
  void ensureLayout({required String createdTs}) {
    root.createSync(recursive: true);
    eventsDir.createSync();
    if (!lockFile.existsSync()) {
      lockFile.createSync();
    }
    if (!manifestFile.existsSync()) {
      manifestFile.writeAsStringSync(
        '${jsonEncode({'format': 'sai-event-log', 'version': 0, 'created': createdTs})}\n',
        flush: true,
      );
    }
    if (!headFile.existsSync()) {
      writeHead(HeadRecord(count: 0, head: null, updated: createdTs));
    }
  }

  HeadRecord readHead() {
    final json = jsonDecode(headFile.readAsStringSync());
    return HeadRecord.fromJson(json as Map<String, Object?>);
  }

  /// Atomic within the file system: write a temp file, fsync, rename over
  /// HEAD (same directory, so the rename cannot cross devices).
  void writeHead(HeadRecord head) {
    final temp = File(p.join(root.path, 'HEAD.tmp'));
    final raf = temp.openSync(mode: FileMode.writeOnly);
    try {
      raf.writeStringSync('${jsonEncode(head.toJson())}\n');
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
    temp.renameSync(headFile.path);
  }

  /// Runs [action] under both the in-process gate and the OS file lock.
  Future<T> withLock<T>(Future<T> Function() action) async {
    final key = root.path;
    final previous = _gates[key] ?? Future<void>.value();
    final gate = Completer<void>();
    _gates[key] = gate.future;
    await previous;
    try {
      final handle = _lockHandle ??= lockFile.openSync(mode: FileMode.append);
      handle.lockSync(FileLock.blockingExclusive);
      try {
        return await action();
      } finally {
        handle.unlockSync();
      }
    } finally {
      gate.complete();
    }
  }

  File dayFile(String day) => File(p.join(eventsDir.path, '$day.jsonl'));

  /// Day files in name order — which is chain order, since names are UTC
  /// dates. Anything not named like a day file (.DS_Store…) is ignored.
  List<File> dayFiles() {
    final files = [
      for (final entry in eventsDir.listSync())
        if (entry is File && _dayFileForm.hasMatch(p.basename(entry.path)))
          entry,
    ];
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// Appends one line. Caller holds the lock. Dart's append mode positions
  /// at end-of-file at open time (there is no O_APPEND underneath), which is
  /// exactly why the open happens inside the locked region.
  void appendLine(File day, List<int> bytes) {
    final raf = day.openSync(mode: FileMode.writeOnlyAppend);
    try {
      raf.writeFromSync(bytes);
      raf.writeStringSync('\n');
      raf.flushSync(); // fsync; see the ADR for the macOS platter caveat
    } finally {
      raf.closeSync();
    }
  }

  /// Splits a day file into complete lines, and reports a torn tail — bytes
  /// after the last newline that never became an event — as the byte offset
  /// where the tear starts, or null when the file ends cleanly.
  (List<String>, int?) readDayLines(File day) {
    final bytes = day.readAsBytesSync();
    if (bytes.isEmpty) return (const <String>[], null);
    final lines = <String>[];
    var start = 0;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] == 0x0a) {
        lines.add(utf8.decode(bytes.sublist(start, i)));
        start = i + 1;
      }
    }
    return (lines, start == bytes.length ? null : start);
  }

  /// The newest complete line of [day] plus torn-tail classification, read
  /// from a bounded window at the end of the file so appends stay O(1) in
  /// the size of the day. Lines are capped at 1 MiB, so a 4 MiB window
  /// always spans the last line boundary of a well-formed file; when it
  /// does not, the file is corrupt and a [FormatException] says so.
  (String?, int?) readTail(File day, {int window = 4 << 20}) {
    final length = day.existsSync() ? day.lengthSync() : 0;
    if (length <= window) {
      final (lines, torn) = readDayLines(day);
      return (lines.isEmpty ? null : lines.last, torn);
    }
    final raf = day.openSync();
    final List<int> bytes;
    try {
      raf.setPositionSync(length - window);
      bytes = raf.readSync(window);
    } finally {
      raf.closeSync();
    }
    final base = length - window;
    var lastNl = -1;
    var prevNl = -1;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] == 0x0a) {
        prevNl = lastNl;
        lastNl = i;
      }
    }
    if (lastNl == -1 || prevNl == -1) {
      throw const FormatException('no line boundary within the tail window');
    }
    final torn = lastNl == bytes.length - 1 ? null : base + lastNl + 1;
    return (utf8.decode(bytes.sublist(prevNl + 1, lastNl)), torn);
  }
}
