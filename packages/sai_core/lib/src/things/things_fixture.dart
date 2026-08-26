/// A synthetic Things 3 database for tests.
///
/// The schema is the 3.23.1 layout of the tables the importer reads (the
/// columns it uses plus the ones the real DDL declares around them); every
/// row is invented here. Nothing in this file, and nothing any test builds
/// with it, comes from a real Things database — the repository is public.
library;

import 'package:sqlite3/sqlite3.dart';

import '../tasks/date.dart';
import 'things_date.dart';

const thingsFixtureDdl = '''
CREATE TABLE 'Meta' ('key' TEXT PRIMARY KEY, 'value' TEXT);
CREATE TABLE 'TMArea' ('uuid' TEXT PRIMARY KEY, 'title' TEXT,
  'visible' INTEGER, 'index' INTEGER, 'cachedTags' BLOB, experimental BLOB);
CREATE TABLE 'TMTag' ('uuid' TEXT PRIMARY KEY, 'title' TEXT,
  'shortcut' TEXT, 'usedDate' REAL, 'parent' TEXT, 'index' INTEGER,
  experimental BLOB);
CREATE TABLE 'TMTaskTag' ('tasks' TEXT NOT NULL, 'tags' TEXT NOT NULL);
CREATE TABLE 'TMAreaTag' ('areas' TEXT NOT NULL, 'tags' TEXT NOT NULL);
CREATE TABLE 'TMChecklistItem' ('uuid' TEXT PRIMARY KEY,
  'userModificationDate' REAL, 'creationDate' REAL, 'title' TEXT,
  'status' INTEGER, 'stopDate' REAL, 'index' INTEGER, 'task' TEXT,
  'leavesTombstone' INTEGER, experimental BLOB);
CREATE TABLE TMTask (
  "uuid" TEXT PRIMARY KEY, "leavesTombstone" INTEGER,
  "creationDate" REAL, "userModificationDate" REAL,
  "type" INTEGER, "status" INTEGER, "stopDate" REAL, "trashed" INTEGER,
  "title" TEXT, "notes" TEXT, "notesSync" INTEGER, "cachedTags" BLOB,
  "start" INTEGER, "startDate" INTEGER, "startBucket" INTEGER,
  "reminderTime" INTEGER, "lastReminderInteractionDate" REAL,
  "deadline" INTEGER, "deadlineSuppressionDate" INTEGER,
  "t2_deadlineOffset" INTEGER,
  "index" INTEGER, "todayIndex" INTEGER, "todayIndexReferenceDate" INTEGER,
  "area" TEXT, "project" TEXT, "heading" TEXT, "contact" TEXT,
  "untrashedLeafActionsCount" INTEGER, "openUntrashedLeafActionsCount" INTEGER,
  "checklistItemsCount" INTEGER, "openChecklistItemsCount" INTEGER,
  "rt1_repeatingTemplate" TEXT, "rt1_recurrenceRule" BLOB,
  "rt1_instanceCreationStartDate" INTEGER, "rt1_instanceCreationPaused" INTEGER,
  "rt1_instanceCreationCount" INTEGER, "rt1_afterCompletionReferenceDate" INTEGER,
  "rt1_nextInstanceStartDate" INTEGER,
  "experimental" BLOB, "repeater" BLOB, "repeaterMigrationDate" REAL
);
''';

/// Unix seconds for a UTC instant.
double thingsSeconds(DateTime instant) =>
    instant.microsecondsSinceEpoch / Duration.microsecondsPerSecond;

/// Builds a Things database file row by row. Every method returns the
/// uuid it assigned, so a test can link rows without inventing ids.
final class ThingsFixture {
  ThingsFixture(this.path) : _db = sqlite3.open(path) {
    _db.execute(thingsFixtureDdl);
    _db.execute('pragma journal_mode = wal');
  }

  /// Opens an existing fixture database for further rows or raw SQL.
  ThingsFixture.reopen(this.path) : _db = sqlite3.open(path) {
    _next =
        (_db.select('select count(*) as n from TMTask').single['n'] as int) +
        (_db.select('select count(*) as n from TMArea').single['n'] as int) +
        (_db.select('select count(*) as n from TMTag').single['n'] as int) +
        (_db.select('select count(*) as n from TMChecklistItem').single['n']
            as int);
    _index = _next;
  }

  final String path;
  final Database _db;
  var _next = 0;
  var _index = 0;

  String _uuid(String kind) => '$kind-${(++_next).toString().padLeft(3, '0')}';

  /// The database as an opened handle for tests that need raw SQL.
  Database get db => _db;

  String area(String title, {bool visible = true}) {
    final uuid = _uuid('area');
    _db.execute(
      'insert into TMArea (uuid, title, visible, "index") values (?, ?, ?, ?)',
      [uuid, title, visible ? 1 : 0, _index++],
    );
    return uuid;
  }

  String tag(String title, {String? parent, String? shortcut}) {
    final uuid = _uuid('tag');
    _db.execute(
      'insert into TMTag (uuid, title, shortcut, parent, "index") '
      'values (?, ?, ?, ?, ?)',
      [uuid, title, shortcut, parent, _index++],
    );
    return uuid;
  }

  /// A `TMTask` row of any type; defaults are an open, untrashed Inbox task
  /// created at [created].
  String item(
    String title, {
    int type = 0,
    int status = 0,
    bool trashed = false,
    String notes = '',
    DateTime? created,
    DateTime? modified,
    DateTime? stopped,
    int start = 0,
    CalendarDate? startDate,
    int startBucket = 0,
    CalendarDate? deadline,
    int? todayIndex,
    String? area,
    String? project,
    String? heading,
    int? reminderTime,
    String? contact,
    String? repeatingTemplate,
    bool template = false,
  }) {
    final uuid = _uuid(switch (type) {
      1 => 'project',
      2 => 'heading',
      _ => 'task',
    });
    final createdAt = created ?? DateTime.utc(2024, 1, 1, 12);
    _db.execute(
      'insert into TMTask (uuid, creationDate, userModificationDate, type, '
      'status, stopDate, trashed, title, notes, start, startDate, '
      'startBucket, deadline, "index", todayIndex, area, project, heading, '
      'reminderTime, contact, rt1_repeatingTemplate, rt1_recurrenceRule) '
      'values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        uuid,
        thingsSeconds(createdAt),
        thingsSeconds(modified ?? createdAt),
        type,
        status,
        stopped == null ? null : thingsSeconds(stopped),
        trashed ? 1 : 0,
        title,
        notes,
        start,
        startDate == null ? null : encodeThingsDay(startDate),
        startBucket,
        deadline == null ? null : encodeThingsDay(deadline),
        _index++,
        todayIndex ?? 0,
        area,
        project,
        heading,
        reminderTime,
        contact,
        repeatingTemplate,
        template ? [1, 2, 3] : null,
      ],
    );
    return uuid;
  }

  String project(
    String title, {
    String? area,
    int status = 0,
    bool trashed = false,
    String notes = '',
    DateTime? created,
    DateTime? stopped,
    int start = 1,
    CalendarDate? startDate,
    CalendarDate? deadline,
  }) => item(
    title,
    type: 1,
    area: area,
    status: status,
    trashed: trashed,
    notes: notes,
    created: created,
    stopped: stopped,
    start: start,
    startDate: startDate,
    deadline: deadline,
  );

  String heading(
    String title, {
    required String project,
    bool trashed = false,
  }) => item(title, type: 2, project: project, trashed: trashed);

  String checklist(
    String task,
    String title, {
    int status = 0,
    DateTime? stopped,
  }) {
    final uuid = _uuid('check');
    _db.execute(
      'insert into TMChecklistItem (uuid, task, title, status, stopDate, '
      '"index", creationDate) values (?, ?, ?, ?, ?, ?, ?)',
      [
        uuid,
        task,
        title,
        status,
        stopped == null ? null : thingsSeconds(stopped),
        _index++,
        thingsSeconds(DateTime.utc(2024, 1, 1, 12)),
      ],
    );
    return uuid;
  }

  void tagTask(String task, String tag) => _db.execute(
    'insert into TMTaskTag (tasks, tags) values (?, ?)',
    [task, tag],
  );

  void tagArea(String area, String tag) => _db.execute(
    'insert into TMAreaTag (areas, tags) values (?, ?)',
    [area, tag],
  );

  /// Flushes without checkpointing, so the newest rows live only in the
  /// WAL — what a running Things leaves behind.
  void close() => _db.dispose();
}
