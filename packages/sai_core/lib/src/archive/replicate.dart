part of 'archive.dart';

/// What one replication did: the replica's proven count and head, and
/// what it cost to get there.
final class ReplicaReport {
  const ReplicaReport({
    required this.count,
    required this.head,
    required this.filesCopied,
    required this.bytesCopied,
  });

  final int count;
  final BlobRef? head;

  /// Day files written this run — only the ones that were absent or had
  /// grown; an unchanged day is left alone.
  final int filesCopied;
  final int bytesCopied;

  @override
  String toString() =>
      'ReplicaReport(count: $count, head: $head, '
      'filesCopied: $filesCopied, bytesCopied: $bytesCopied)';
}

/// The destination cannot be a replica of this archive: it is the archive
/// itself or shares its tree, it holds another archive, or it holds bytes
/// this archive does not — a replica is only ever behind its source, and
/// nothing here overwrites what it finds (#15). Nothing was written.
final class ReplicaRefusedError implements Exception {
  const ReplicaRefusedError(this.reason);

  final String reason;

  @override
  String toString() => 'ReplicaRefusedError: $reason';
}

/// The destination is not there right now — an external volume that is
/// not mounted, a path whose parent does not exist. Not an error in the
/// archive or the replica; nothing was created, try again later.
final class ReplicaUnavailableError implements Exception {
  const ReplicaUnavailableError(this.reason);

  final String reason;

  @override
  String toString() => 'ReplicaUnavailableError: $reason';
}

/// Copies read this many bytes at a time, with a turn of the event loop
/// between chunks so a large day never stalls a client's frame.
const int _copyChunk = 1 << 20;

extension _Replication on Archive {
  /// [Archive.replicateTo]'s body. The replica's own lock is taken first
  /// and the source's inside it: two replicators (the app, the hourly
  /// job) serialize on the replica, and the writer — which takes only the
  /// source lock — never waits behind a whole copy.
  Future<ReplicaReport> _replicateTo(Directory destination) async {
    _refuseOverlap(_store.root, destination);
    if (!destination.parent.existsSync()) {
      throw const ReplicaUnavailableError(
        'the destination is not mounted (its parent does not exist)',
      );
    }
    final replica = ArchiveStore(destination);
    _refuseForeign(replica);
    replica.ensureRoot();
    _removeLeftovers(replica);
    try {
      return await replica.withLock(
        () => _store.withLock(() async {
          var filesCopied = 0;
          var bytesCopied = 0;
          if (!replica.manifestFile.existsSync()) {
            bytesCopied += await _copyFile(
              _store.manifestFile,
              replica.manifestFile,
            );
          }
          final head = _readHead();
          final sources = _store.dayFiles();
          final targets = {
            for (final file in replica.dayFiles()) p.basename(file.path): file,
          };
          final names = {for (final file in sources) p.basename(file.path)};
          for (final name in targets.keys) {
            if (!names.contains(name)) {
              throw ReplicaRefusedError(
                'the replica has diverged: it holds $name, which the archive '
                'does not',
              );
            }
          }
          for (final (index, source) in sources.indexed) {
            final name = p.basename(source.path);
            final target = targets[name];
            final sourceLength = source.lengthSync();
            final targetLength = target?.lengthSync() ?? 0;
            if (targetLength > sourceLength) {
              throw ReplicaRefusedError(
                'the replica has diverged: its $name is longer than the '
                "archive's",
              );
            }
            if (targetLength == sourceLength && target != null) {
              // Older days never change once written; the newest can only
              // have grown, so an equal length means an equal last line —
              // unless something else wrote there.
              if (index == sources.length - 1 && !_sameTail(source, target)) {
                throw ReplicaRefusedError(
                  'the replica has diverged: its $name ends in another line',
                );
              }
              continue;
            }
            bytesCopied += await _copyFile(
              source,
              replica.dayFile(p.basenameWithoutExtension(name)),
            );
            filesCopied++;
          }
          replica.writeHead(head);
          final report = await Archive._(replica, _clock)._walkAndCheckHead();
          return ReplicaReport(
            count: report.count,
            head: report.head,
            filesCopied: filesCopied,
            bytesCopied: bytesCopied,
          );
        }),
      );
    } finally {
      await replica.close();
    }
  }

  /// A replica carries its source's MANIFEST: a different `created` is
  /// another archive, and day files with no manifest are nobody's replica.
  void _refuseForeign(ArchiveStore replica) {
    if (replica.manifestFile.existsSync()) {
      if (_manifestCreated(replica) != _manifestCreated(_store)) {
        throw const ReplicaRefusedError(
          'the destination holds another archive (its manifest names a '
          'different creation time)',
        );
      }
    } else if (replica.eventsDir.existsSync() &&
        replica.dayFiles().isNotEmpty) {
      throw const ReplicaRefusedError(
        'the destination holds day files but no manifest; it is not a '
        'replica of this archive',
      );
    }
  }

  String? _manifestCreated(ArchiveStore store) {
    final Object? manifest;
    try {
      manifest = jsonDecode(store.manifestFile.readAsStringSync());
    } on FormatException catch (e) {
      throw ArchiveCorruptionError(
        file: store.manifestFile.path,
        reason: 'MANIFEST.json is not JSON: ${e.message}',
      );
    }
    if (manifest is! Map<String, Object?>) {
      throw ArchiveCorruptionError(
        file: store.manifestFile.path,
        reason: 'MANIFEST.json is not an object',
      );
    }
    return manifest['created'] as String?;
  }

  /// A `.jsonl.tmp` under `events/` is this routine's own interrupted
  /// copy — never a day file (the name pattern excludes it) and never
  /// worth keeping.
  void _removeLeftovers(ArchiveStore replica) {
    for (final entry in replica.eventsDir.listSync()) {
      if (entry is File && entry.path.endsWith('.jsonl.tmp')) {
        entry.deleteSync();
      }
    }
  }

  bool _sameTail(File source, File target) {
    final (a, _) = _store.readTail(source);
    final (b, _) = _store.readTail(target);
    return a == b;
  }
}

/// [Archive.restore]'s body: the replica is read in place — never opened,
/// so it gains no LOCK and its HEAD is never rewritten — and the target
/// takes it under its own lock.
Future<ArchiveReport> _restore({
  required Directory from,
  required Directory into,
  required DateTime Function() clock,
}) async {
  _refuseOverlap(from, into);
  final source = ArchiveStore(from);
  if (!source.manifestFile.existsSync() ||
      !source.headFile.existsSync() ||
      !source.eventsDir.existsSync()) {
    throw const ReplicaRefusedError(
      'the replica is not an archive: no MANIFEST.json, HEAD and events/',
    );
  }
  final reader = Archive._(source, clock);
  if (source.dayFiles().isEmpty) {
    throw const ReplicaRefusedError('the replica holds no events');
  }
  // What the replica proves about itself: a HEAD that is a truthful
  // prefix of its chain (a replication interrupted before HEAD was
  // written) is accepted and rolled forward in the copy, never in place.
  final tail = await reader._tailState();
  var count = 0;
  BlobRef? last;
  await for (final stored in reader.events()) {
    count++;
    last = stored.id;
  }
  if (count != tail.count || last != tail.head) {
    throw ArchiveCorruptionError(
      file: source.headFile.path,
      reason:
          'HEAD records count ${tail.count} head ${tail.head}, '
          'files hold count $count head $last',
    );
  }
  final target = ArchiveStore(into);
  target.ensureRoot();
  try {
    return await target.withLock(() async {
      if (target.dayFiles().isNotEmpty) {
        throw const ReplicaRefusedError(
          'the archive root is not empty: move it aside, then restore',
        );
      }
      if (target.headFile.existsSync()) {
        final HeadRecord head;
        try {
          head = target.readHead();
        } on FormatException catch (e) {
          throw ArchiveCorruptionError(
            file: target.headFile.path,
            reason: e.message,
          );
        }
        if (head.count != 0) {
          throw ReplicaRefusedError(
            'the archive root is not empty: its HEAD counts ${head.count} '
            'events but no day file holds them; move it aside, then restore',
          );
        }
      }
      await _copyFile(source.manifestFile, target.manifestFile);
      for (final file in source.dayFiles()) {
        await _copyFile(
          file,
          target.dayFile(p.basenameWithoutExtension(file.path)),
        );
      }
      target.writeHead(
        HeadRecord(
          count: tail.count,
          head: tail.head,
          updated: formatTs(clock()),
        ),
      );
      return Archive._(target, clock)._walkAndCheckHead();
    });
  } finally {
    await target.close();
  }
}

/// A [destination] that is the [source], lies inside it, or contains it —
/// judged on resolved paths, so a symlink to the root is the root.
void _refuseOverlap(Directory source, Directory destination) {
  final a = _resolved(source);
  final b = _resolved(destination);
  if (p.equals(a, b)) {
    throw const ReplicaRefusedError('the destination is the archive itself');
  }
  if (p.isWithin(a, b)) {
    throw const ReplicaRefusedError('the destination is inside the archive');
  }
  if (p.isWithin(b, a)) {
    throw const ReplicaRefusedError('the destination contains the archive');
  }
}

/// [directory]'s path with symlinks resolved as far as it exists: the
/// deepest existing ancestor is resolved and the rest rejoined.
String _resolved(Directory directory) {
  var path = p.normalize(directory.absolute.path);
  final rest = <String>[];
  while (!FileSystemEntity.isDirectorySync(path) && !File(path).existsSync()) {
    final parent = p.dirname(path);
    if (parent == path) break;
    rest.insert(0, p.basename(path));
    path = parent;
  }
  try {
    path = Directory(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    // Not a directory after all; the unresolved path is what there is.
  }
  return p.normalize(p.joinAll([path, ...rest]));
}

/// Copies [source] to [target] through `<target>.tmp` in the target's
/// directory — fsync, then a rename that cannot cross devices — in
/// chunks with a turn between them. Returns the bytes written.
Future<int> _copyFile(File source, File target) async {
  final temp = File('${target.path}.tmp');
  final input = source.openSync();
  final output = temp.openSync(mode: FileMode.writeOnly);
  var written = 0;
  try {
    while (true) {
      final chunk = input.readSync(_copyChunk);
      if (chunk.isEmpty) break;
      output.writeFromSync(chunk);
      written += chunk.length;
      await Future<void>.delayed(Duration.zero);
    }
    output.flushSync();
  } finally {
    input.closeSync();
    output.closeSync();
  }
  temp.renameSync(target.path);
  return written;
}
