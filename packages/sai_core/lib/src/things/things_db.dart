/// Reading the Things 3 database without touching it.
///
/// Things keeps a WAL-mode SQLite file in its group container and holds
/// it open while the app runs. The reader never opens that file: it
/// copies `main.sqlite` with its `-wal` and `-shm` companions into a
/// private temporary directory, reads the copy, and deletes it on
/// [ThingsDatabase.dispose]. An `immutable` open of the original
/// would skip the WAL and miss the newest edits; a plain open would let
/// SQLite write the `-shm` file inside another app's container.
///
/// Rows come out as plain records with Things' own encodings intact
/// (packed days, Unix seconds, integer enums); the mapping decodes them.
/// Nothing here logs or embeds a title or a note.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// The Things version this reader and mapping were verified against.
const thingsVerifiedVersion = '3.23.1';

/// The environment variable that names the database file explicitly —
/// for a scratch run against a copy, or a test fixture.
const thingsDatabaseEnv = 'SAI_THINGS_DB';

/// Where Things 3 keeps its database, relative to the home directory. The
/// `ThingsData-XXXXX` segment differs per installation.
const thingsContainerRelative =
    'Library/Group Containers/JLMPQHK86H.com.culturedcode.ThingsMac';
const _databaseRelative = 'Things Database.thingsdatabase/main.sqlite';

/// The path of the Things database to read, or null when none is found.
///
/// [thingsDatabaseEnv] wins when set and non-empty; otherwise the first
/// `ThingsData-*` directory (sorted) under the group container in [home].
String? locateThingsDatabase({
  required Map<String, String> environment,
  required String home,
}) {
  final explicit = environment[thingsDatabaseEnv];
  if (explicit != null && explicit.isNotEmpty) return explicit;
  final container = Directory(p.join(home, thingsContainerRelative));
  if (!container.existsSync()) return null;
  final candidates =
      container
          .listSync()
          .whereType<Directory>()
          .where((d) => p.basename(d.path).startsWith('ThingsData-'))
          .map((d) => p.join(d.path, _databaseRelative))
          .where((path) => File(path).existsSync())
          .toList()
        ..sort();
  return candidates.isEmpty ? null : candidates.first;
}

/// The database is not a Things 3 database this reader understands. The
/// message names a table or column, never data.
final class ThingsSchemaException implements Exception {
  ThingsSchemaException(this.message) : retryable = false;

  /// A copy that SQLite reports as torn; another copy may be whole.
  ThingsSchemaException.inconsistent(this.message) : retryable = true;

  final String message;
  final bool retryable;

  @override
  String toString() => 'ThingsSchemaException: $message';
}

/// One row of `TMArea`.
final class ThingsArea {
  const ThingsArea({
    required this.uuid,
    required this.title,
    required this.visible,
    required this.index,
  });

  final String uuid;
  final String title;
  final bool visible;
  final int index;
}

/// One row of `TMTag`.
final class ThingsTag {
  const ThingsTag({
    required this.uuid,
    required this.title,
    required this.shortcut,
    required this.parent,
    required this.index,
  });

  final String uuid;
  final String title;
  final String? shortcut;
  final String? parent;
  final int index;
}

/// `TMTask.type`.
enum ThingsItemType { task, project, heading }

/// `TMTask.status` and `TMChecklistItem.status`.
enum ThingsStatus { open, cancelled, completed }

/// `TMTask.start`.
enum ThingsStart { inbox, anytime, someday }

/// One row of `TMTask` — a task, a project or a heading.
final class ThingsItem {
  const ThingsItem({
    required this.uuid,
    required this.type,
    required this.status,
    required this.trashed,
    required this.title,
    required this.notes,
    required this.creationDate,
    required this.modificationDate,
    required this.stopDate,
    required this.start,
    required this.startDate,
    required this.startBucket,
    required this.deadline,
    required this.index,
    required this.todayIndex,
    required this.area,
    required this.project,
    required this.heading,
    required this.reminderTime,
    required this.contact,
    required this.repeatingTemplate,
    required this.isRepeatingTemplate,
  });

  final String uuid;
  final ThingsItemType type;
  final ThingsStatus status;
  final bool trashed;
  final String title;
  final String notes;

  /// Unix seconds.
  final double? creationDate;
  final double? modificationDate;
  final double? stopDate;

  final ThingsStart start;

  /// Packed Things days.
  final int? startDate;
  final int startBucket;
  final int? deadline;

  final int index;
  final int todayIndex;

  /// Parent uuids; a task has at most one placement in practice, a
  /// heading always names its project.
  final String? area;
  final String? project;
  final String? heading;

  final int? reminderTime;
  final String? contact;

  /// The template a repeating instance was generated from.
  final String? repeatingTemplate;

  /// True for the template itself (`rt1_recurrenceRule` set).
  final bool isRepeatingTemplate;
}

/// One row of `TMChecklistItem`.
final class ThingsChecklistItem {
  const ThingsChecklistItem({
    required this.uuid,
    required this.task,
    required this.title,
    required this.status,
    required this.stopDate,
    required this.index,
  });

  final String uuid;
  final String task;
  final String title;
  final ThingsStatus status;
  final double? stopDate;
  final int index;
}

/// Everything the mapping needs, read in one pass.
final class ThingsSnapshot {
  const ThingsSnapshot({
    required this.areas,
    required this.tags,
    required this.items,
    required this.checklistItems,
    required this.taskTags,
    required this.areaTags,
  });

  final List<ThingsArea> areas;
  final List<ThingsTag> tags;
  final List<ThingsItem> items;
  final List<ThingsChecklistItem> checklistItems;

  /// Task uuid → tag uuids, in `TMTaskTag` row order.
  final Map<String, List<String>> taskTags;

  /// Area uuid → tag uuids.
  final Map<String, List<String>> areaTags;
}

/// A read-only handle over a private copy of a Things database.
final class ThingsDatabase {
  ThingsDatabase._(this._db, this._copy, this.sourcePath);

  /// Copies the database at [path] (with its WAL and shared-memory files
  /// when present) into a fresh temporary directory and opens the copy.
  /// Throws [ThingsSchemaException] when the copy lacks the
  /// tables and columns this reader uses; a missing file surfaces as the
  /// usual [FileSystemException].
  static ThingsDatabase snapshot(String path) {
    final source = File(path);
    if (!source.existsSync()) {
      throw FileSystemException('Things database not found', path);
    }
    // Things may checkpoint or reset its WAL while the three files are
    // being copied, leaving a set from two generations, or remove a
    // companion between the existence check and the copy. A copy is
    // trusted only once SQLite has checked it; otherwise it is thrown
    // away and taken again.
    ThingsSchemaException? last;
    for (var attempt = 0; attempt < snapshotAttempts; attempt++) {
      final copy = Directory.systemTemp.createTempSync('sai_things_copy_');
      try {
        final target = p.join(copy.path, 'main.sqlite');
        source.copySync(target);
        for (final suffix in const ['-wal', '-shm']) {
          final companion = File('$path$suffix');
          try {
            companion.copySync('$target$suffix');
          } on FileSystemException {
            // Gone since the main file was copied; a checkpoint folded
            // it into main.sqlite, which the check below confirms.
          }
        }
        final Database db;
        try {
          // Read-write on purpose, on the copy: a WAL database needs its
          // shared-memory file, and a read-only connection cannot create
          // one when the companions were not there to copy. Nothing here
          // writes.
          db = sqlite3.open(target, mode: OpenMode.readWrite);
        } on SqliteException catch (e) {
          throw ThingsSchemaException('not an SQLite database (${e.message})');
        }
        try {
          try {
            _checkIntegrity(db);
          } on SqliteException catch (e) {
            // A torn copy can fail inside the check itself.
            throw ThingsSchemaException.inconsistent(e.message);
          }
          try {
            _checkSchema(db);
          } on SqliteException catch (e) {
            throw ThingsSchemaException(
              'not an SQLite database (${e.message})',
            );
          }
        } catch (_) {
          db.close();
          rethrow;
        }
        return ThingsDatabase._(db, copy, path);
      } on ThingsSchemaException catch (e) {
        copy.deleteSync(recursive: true);
        last = e;
        if (!e.retryable) rethrow;
      } catch (_) {
        copy.deleteSync(recursive: true);
        rethrow;
      }
    }
    throw ThingsSchemaException(
      'no consistent snapshot after $snapshotAttempts attempts '
      '(${last!.message})',
    );
  }

  /// How often [snapshot] retries a copy SQLite reports as inconsistent.
  static const snapshotAttempts = 3;

  /// `pragma quick_check` over the copy: a torn copy of a WAL database
  /// shows up here as a corrupt page or a bad header.
  static void _checkIntegrity(Database db) {
    final rows = db.select('pragma quick_check');
    if (rows.length != 1 || rows.single.columnAt(0) != 'ok') {
      throw ThingsSchemaException.inconsistent(
        'the copy did not pass quick_check',
      );
    }
  }

  final Database _db;
  final Directory _copy;

  /// The private directory holding the copy; gone after [dispose].
  Directory get copyDirectory => _copy;

  /// The path the snapshot was taken from.
  final String sourcePath;

  static const _required = {
    'TMArea': ['uuid', 'title', 'visible', 'index'],
    'TMTag': ['uuid', 'title', 'shortcut', 'parent', 'index'],
    'TMTask': [
      'uuid',
      'type',
      'status',
      'trashed',
      'title',
      'notes',
      'creationDate',
      'userModificationDate',
      'stopDate',
      'start',
      'startDate',
      'startBucket',
      'deadline',
      'index',
      'todayIndex',
      'area',
      'project',
      'heading',
      'reminderTime',
      'contact',
      'rt1_repeatingTemplate',
      'rt1_recurrenceRule',
    ],
    'TMChecklistItem': ['uuid', 'task', 'title', 'status', 'stopDate', 'index'],
    'TMTaskTag': ['tasks', 'tags'],
    'TMAreaTag': ['areas', 'tags'],
  };

  static void _checkSchema(Database db) {
    for (final entry in _required.entries) {
      final columns = db
          .select('select name from pragma_table_info(?)', [entry.key])
          .map((row) => row['name'] as String)
          .toSet();
      if (columns.isEmpty) {
        throw ThingsSchemaException('missing table ${entry.key}');
      }
      for (final column in entry.value) {
        if (!columns.contains(column)) {
          throw ThingsSchemaException('missing column ${entry.key}.$column');
        }
      }
    }
  }

  /// Reads every table the mapping uses.
  ThingsSnapshot read() {
    final areas = [
      for (final row in _db.select(
        'select uuid, title, visible, "index" from TMArea order by "index", uuid',
      ))
        ThingsArea(
          uuid: row['uuid'] as String,
          title: (row['title'] as String?) ?? '',
          visible: (row['visible'] as int?) != 0,
          index: (row['index'] as int?) ?? 0,
        ),
    ];
    final tags = [
      for (final row in _db.select(
        'select uuid, title, shortcut, parent, "index" from TMTag '
        'order by "index", uuid',
      ))
        ThingsTag(
          uuid: row['uuid'] as String,
          title: (row['title'] as String?) ?? '',
          shortcut: row['shortcut'] as String?,
          parent: row['parent'] as String?,
          index: (row['index'] as int?) ?? 0,
        ),
    ];
    final items = [
      for (final row in _db.select(
        'select uuid, type, status, trashed, title, notes, creationDate, '
        'userModificationDate, stopDate, start, startDate, startBucket, '
        'deadline, "index", todayIndex, area, project, heading, '
        'reminderTime, contact, rt1_repeatingTemplate, '
        '(rt1_recurrenceRule is not null) as isTemplate '
        'from TMTask order by "index", uuid',
      ))
        ThingsItem(
          uuid: row['uuid'] as String,
          type: switch (row['type'] as int?) {
            1 => ThingsItemType.project,
            2 => ThingsItemType.heading,
            _ => ThingsItemType.task,
          },
          status: _status(row['status'] as int?),
          trashed: (row['trashed'] as int?) == 1,
          title: (row['title'] as String?) ?? '',
          notes: (row['notes'] as String?) ?? '',
          creationDate: _real(row['creationDate']),
          modificationDate: _real(row['userModificationDate']),
          stopDate: _real(row['stopDate']),
          start: switch (row['start'] as int?) {
            1 => ThingsStart.anytime,
            2 => ThingsStart.someday,
            _ => ThingsStart.inbox,
          },
          startDate: row['startDate'] as int?,
          startBucket: (row['startBucket'] as int?) ?? 0,
          deadline: row['deadline'] as int?,
          index: (row['index'] as int?) ?? 0,
          todayIndex: (row['todayIndex'] as int?) ?? 0,
          area: row['area'] as String?,
          project: row['project'] as String?,
          heading: row['heading'] as String?,
          reminderTime: row['reminderTime'] as int?,
          contact: row['contact'] as String?,
          repeatingTemplate: row['rt1_repeatingTemplate'] as String?,
          isRepeatingTemplate: (row['isTemplate'] as int) == 1,
        ),
    ];
    final checklistItems = [
      for (final row in _db.select(
        'select uuid, task, title, status, stopDate, "index" '
        'from TMChecklistItem where task is not null order by "index", uuid',
      ))
        ThingsChecklistItem(
          uuid: row['uuid'] as String,
          task: row['task'] as String,
          title: (row['title'] as String?) ?? '',
          status: _status(row['status'] as int?),
          stopDate: _real(row['stopDate']),
          index: (row['index'] as int?) ?? 0,
        ),
    ];
    return ThingsSnapshot(
      areas: areas,
      tags: tags,
      items: items,
      checklistItems: checklistItems,
      taskTags: _links('select tasks as a, tags as b from TMTaskTag'),
      areaTags: _links('select areas as a, tags as b from TMAreaTag'),
    );
  }

  Map<String, List<String>> _links(String sql) {
    final links = <String, List<String>>{};
    for (final row in _db.select(sql)) {
      links.putIfAbsent(row['a'] as String, () => []).add(row['b'] as String);
    }
    return links;
  }

  static ThingsStatus _status(int? raw) => switch (raw) {
    2 => ThingsStatus.cancelled,
    3 => ThingsStatus.completed,
    _ => ThingsStatus.open,
  };

  static double? _real(Object? value) => switch (value) {
    null => null,
    final num n => n.toDouble(),
    _ => null,
  };

  /// Closes the copy and deletes it.
  void dispose() {
    _db.close();
    if (_copy.existsSync()) _copy.deleteSync(recursive: true);
  }
}
