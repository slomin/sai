/// What stands between a client and a Things import, said the same way
/// in every client (#40): the failures as a closed set, each naming the
/// next step, and the snapshot read off the main isolate.
///
/// Nothing here carries a title or a note — a failure names a path, a
/// count or a Things uuid at most, so it can be shown, logged and pasted.
library;

import 'dart:io';
import 'dart:isolate';

import 'things_db.dart';
import 'things_import.dart';
import 'things_mapping.dart';

/// Why an import could not start or finish. A closed set read by
/// exhaustive switches; every member has a [headline] and a [nextAction]
/// so a client never has to invent copy from an exception.
sealed class ThingsFailure {
  const ThingsFailure();

  /// What happened, in one line.
  String get headline;

  /// What the person can do about it, in one line.
  String get nextAction;
}

/// No Things 3 database under the group container and none named.
final class ThingsNotFound extends ThingsFailure {
  const ThingsNotFound();

  @override
  String get headline => 'No Things 3 database was found.';

  @override
  String get nextAction =>
      'If Things is installed, choose its main.sqlite yourself — '
      'or start empty and import later from Settings.';
}

/// More than one `ThingsData-*` database and no way to pick.
final class ThingsAmbiguous extends ThingsFailure {
  const ThingsAmbiguous(this.count);

  final int count;

  @override
  String get headline =>
      '$count Things databases were found under the group container.';

  @override
  String get nextAction =>
      'Choose the one Things is using; the others are usually left behind '
      'by an old install.';
}

/// The file could not be read: missing, or permission was refused.
final class ThingsUnreadable extends ThingsFailure {
  const ThingsUnreadable(this.path, this.message);

  final String? path;
  final String message;

  @override
  String get headline => path == null
      ? 'The Things database could not be read.'
      : 'The Things database at $path could not be read.';

  @override
  String get nextAction =>
      'Grant sai Full Disk Access in System Settings › Privacy & Security '
      'and try again, or copy the database somewhere sai can read and '
      'choose the copy.';
}

/// The file is not a Things 3 database this sai understands.
final class ThingsNotADatabase extends ThingsFailure {
  const ThingsNotADatabase(this.message);

  /// Names a table or column, never data.
  final String message;

  @override
  String get headline => 'That is not a Things 3 database ($message).';

  @override
  String get nextAction =>
      'Choose the main.sqlite inside "Things Database.thingsdatabase"; '
      'sai reads Things $thingsVerifiedVersion.';
}

/// Every copy of the database was torn while Things kept writing.
final class ThingsTorn extends ThingsFailure {
  const ThingsTorn(this.message);

  final String message;

  @override
  String get headline => 'No consistent copy of the database could be taken.';

  @override
  String get nextAction =>
      'Things is busy writing; wait a moment and try again, or quit Things '
      'first.';
}

/// The store refused an operation part-way through the run.
final class ThingsStopped extends ThingsFailure {
  const ThingsStopped({
    required this.uuid,
    required this.appended,
    required this.cause,
  });

  /// The Things uuid of the entity that was refused — never its title.
  final String uuid;

  /// Events already written before the refusal; they stay.
  final int appended;
  final String cause;

  @override
  String get headline =>
      'The import stopped after $appended events: $cause (Things item $uuid).';

  @override
  String get nextAction =>
      'What was written stays and is not duplicated — run the import again '
      'to continue from here.';
}

/// The [ThingsFailure] for an error the importer threw. [path] names the
/// file that was being read, when known.
ThingsFailure classifyThingsError(Object error, {String? path}) =>
    switch (error) {
      ThingsAmbiguousDatabase(:final count) => ThingsAmbiguous(count),
      ThingsSchemaException(retryable: true, :final message) => ThingsTorn(
        message,
      ),
      ThingsSchemaException(:final message) => ThingsNotADatabase(message),
      ThingsImportException(:final op, :final appended, :final cause) =>
        ThingsStopped(uuid: op.uuid, appended: appended, cause: '$cause'),
      FileSystemException(:final message, path: final errorPath) =>
        ThingsUnreadable(path ?? errorPath, message),
      _ => ThingsUnreadable(path, '$error'),
    };

/// The snapshot of the database at [path], taken and read on a spawned
/// isolate so the copy and the SQLite pass never stall a client's frame.
/// The private copy is removed before the snapshot comes back. Throws
/// what [ThingsDatabase.snapshot] throws.
Future<ThingsSnapshot> readThingsSnapshot(String path) =>
    Isolate.run(() => _readOnThisIsolate(path));

ThingsSnapshot _readOnThisIsolate(String path) {
  final db = ThingsDatabase.snapshot(path);
  try {
    return db.read();
  } finally {
    db.dispose();
  }
}

/// An [ImportReport.unsupported] bucket as a client shows it: the three
/// buckets that name a command-line option in the terminal say the same
/// thing without the flag; every other bucket is already a sentence.
String unsupportedLabel(String bucket) {
  if (bucket == Unsupported.openOnly) {
    return 'completed and cancelled tasks (open tasks only)';
  }
  if (bucket == Unsupported.repeatHistory) {
    return 'completed and cancelled repeating instances (repeat history '
        'skipped)';
  }
  final logbook = _logbookBefore.firstMatch(bucket);
  if (logbook != null) {
    return 'tasks finished before ${logbook[1]} (Logbook since that day)';
  }
  return bucket;
}

final _logbookBefore = RegExp(
  r'^tasks finished before (\S+) \(--logbook-since\)$',
);
