import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

import 'package:sai_core/things_testing.dart';

void main() {
  late Directory tmp;
  late Archive archive;
  late TaskStore store;
  var nowMicros = DateTime.utc(2026, 8, 26, 12).microsecondsSinceEpoch;
  DateTime clock() {
    nowMicros += 1000000;
    return DateTime.fromMicrosecondsSinceEpoch(nowMicros, isUtc: true);
  }

  final now = DateTime.utc(2026, 8, 26, 12);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sai_things_import_test');
    archive = await Archive.open(
      Directory(p.join(tmp.path, 'archive')),
      clock: clock,
    );
    store = await TaskStore.open(archive, source: 'sai/tui');
  });
  tearDown(() async {
    store.dispose();
    await archive.close();
    tmp.deleteSync(recursive: true);
  });

  List<Map<String, Object?>> logLines() {
    final dir = Directory(p.join(tmp.path, 'archive', 'events'));
    if (!dir.existsSync()) return const [];
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return [
      for (final file in files)
        for (final line in file.readAsLinesSync())
          if (line.isNotEmpty) jsonDecode(line) as Map<String, Object?>,
    ];
  }

  String thingsPath() => p.join(tmp.path, 'main.sqlite');

  ThingsSnapshot snapshot() {
    final db = ThingsDatabase.snapshot(thingsPath());
    addTearDown(db.dispose);
    return db.read();
  }

  ({String home, String kitchen, String shopping, String oat, String done})
  seed() {
    final f = ThingsFixture(thingsPath());
    final home = f.area('Home');
    final errand = f.tag('errand');
    final kitchen = f.project('Kitchen', area: home, start: 1);
    final shopping = f.heading('Shopping', project: kitchen);
    final oat = f.item(
      'Buy oat milk',
      start: 1,
      startDate: const CalendarDate(2026, 8, 24),
      project: kitchen,
      heading: shopping,
      created: DateTime.utc(2024, 3, 2, 9),
    );
    f.tagTask(oat, errand);
    f.checklist(oat, 'oat');
    final done = f.item(
      'Paint wall',
      project: kitchen,
      status: 3,
      stopped: DateTime.utc(2026, 8, 20, 8),
    );
    f.close();
    return (
      home: home,
      kitchen: kitchen,
      shopping: shopping,
      oat: oat,
      done: done,
    );
  }

  test(
    'a first run writes system events with external and created_at',
    () async {
      final ids = seed();
      final result = await importThings(snapshot(), store: store, now: now);

      expect(result.dryRun, isFalse);
      expect(result.plan.length, 6);
      // 6 creates + 1 completion.
      expect(result.eventsAppended, 7);
      final lines = logLines();
      expect(lines.length, 7);
      expect(lines.map((l) => l['actor']).toSet(), {'system'});
      expect(lines.map((l) => l['type']), [
        'area.create',
        'tag.create',
        'project.create',
        'heading.create',
        'task.create',
        'task.create',
        'task.complete',
      ]);
      final oat = lines[4]['payload'] as Map<String, Object?>;
      expect(oat['external'], {
        'system': 'things3',
        'id': ids.oat,
        'version': thingsVerifiedVersion,
      });
      expect(oat['created_at'], '2024-03-02T09:00:00.000000Z');
      expect(oat['when'], '2026-08-24');
      expect(oat['checklist'], [
        {'title': 'oat', 'completed_at': null},
      ]);
      final complete = lines[6]['payload'] as Map<String, Object?>;
      expect(complete['at'], '2026-08-20T08:00:00.000000Z');

      final task = store.projection.byExternal(
        ExternalSystems.things3,
        ids.oat,
      )!;
      expect(task.title, 'Buy oat milk');
      expect(
        task.heading,
        store.projection.idByExternal('things3', ids.shopping),
      );
      expect(
        task.project,
        store.projection.idByExternal('things3', ids.kitchen),
      );
      expect(task.tags, hasLength(1));
      final done = store.projection.byExternal(
        ExternalSystems.things3,
        ids.done,
      )!;
      expect(done.status, TaskStatus.completed);
      expect(store.canUndo, isFalse);
    },
  );

  test('a second run over the same database appends nothing', () async {
    seed();
    await importThings(snapshot(), store: store, now: now);
    final count = logLines().length;

    final again = await importThings(snapshot(), store: store, now: now);

    expect(again.plan.isEmpty, isTrue);
    expect(again.eventsAppended, 0);
    expect(logLines().length, count);
    expect(again.report.tasks.unchanged, 2);
    expect(again.report.tasks.created, 0);
    expect(again.report.areas.unchanged, 1);
  });

  test('a changed database yields exactly the diff', () async {
    final ids = seed();
    await importThings(snapshot(), store: store, now: now);
    final count = logLines().length;

    final f = ThingsFixture.reopen(thingsPath());
    f.db.execute(
      'update TMTask set title = ?, status = 3, stopDate = ?, heading = null '
      'where uuid = ?',
      [
        'Buy oat milk (2l)',
        thingsSeconds(DateTime.utc(2026, 8, 25, 7)),
        ids.oat,
      ],
    );
    f.db.execute(
      'update TMTask set status = 0, stopDate = null where uuid = ?',
      [ids.done],
    );
    f.db.execute('update TMArea set title = ? where uuid = ?', [
      'Home sweet home',
      ids.home,
    ]);
    final newTask = f.item('Wipe counter', project: ids.kitchen);
    f.close();

    final result = await importThings(snapshot(), store: store, now: now);

    expect(result.plan.ops.map((op) => (op.runtimeType, op.uuid)), [
      (EditArea, ids.home),
      (EditTask, ids.oat),
      (MoveTask, ids.oat),
      (SetTaskStatus, ids.oat),
      (SetTaskStatus, ids.done),
      (CreateTask, newTask),
    ]);
    expect(result.eventsAppended, 6);
    expect(logLines().length, count + 6);
    expect(result.report.tasks.updated, 2);
    expect(result.report.tasks.created, 1);
    expect(result.report.areas.updated, 1);
    final oat = store.projection.byExternal('things3', ids.oat)!;
    expect(oat.title, 'Buy oat milk (2l)');
    expect(oat.heading, isNull);
    expect(oat.project, store.projection.idByExternal('things3', ids.kitchen));
    expect(oat.completedAt, DateTime.utc(2026, 8, 25, 7));
    expect(
      store.projection.byExternal('things3', ids.done)!.status,
      TaskStatus.open,
    );
    expect(store.projection.byExternal('things3', newTask), isNotNull);

    final third = await importThings(snapshot(), store: store, now: now);
    expect(third.plan.isEmpty, isTrue);
  });

  test(
    'a heading moved to another project keeps its tasks importable',
    () async {
      final ids = seed();
      await importThings(snapshot(), store: store, now: now);
      final count = logLines().length;

      final f = ThingsFixture.reopen(thingsPath());
      final garage = f.project('Garage', start: 1);
      f.db.execute('update TMTask set project = ? where uuid in (?, ?)', [
        garage,
        ids.shopping,
        ids.oat,
      ]);
      f.close();

      final result = await importThings(snapshot(), store: store, now: now);

      expect(result.plan.ops.map((op) => (op.runtimeType, op.uuid)), [
        (CreateProject, garage),
        (MoveTask, ids.oat),
      ]);
      expect(logLines().length, count + 2);
      expect(result.report.unsupported[Unsupported.movedHeadings], 1);
      expect(result.report.headings.unchanged, 0);
      final oat = store.projection.byExternal('things3', ids.oat)!;
      expect(oat.project, store.projection.idByExternal('things3', garage));
      expect(oat.heading, isNull);
      // The sai heading stays in its old project, untouched.
      final heading = store
          .projection
          .headings[store.projection.idByExternal('things3', ids.shopping)!]!;
      expect(
        heading.project,
        store.projection.idByExternal('things3', ids.kitchen),
      );

      final third = await importThings(snapshot(), store: store, now: now);
      expect(third.plan.isEmpty, isTrue);
      expect(third.report.unsupported[Unsupported.movedHeadings], 1);
    },
  );

  test('a dry run plans the same operations and appends nothing', () async {
    seed();
    final dry = await importThings(
      snapshot(),
      store: store,
      now: now,
      dryRun: true,
    );
    expect(dry.dryRun, isTrue);
    expect(dry.plan.length, 6);
    expect(dry.eventsAppended, 0);
    expect(logLines(), isEmpty);
    expect(
      dry.plan.ops.map((op) => op.describe()).first,
      startsWith('+ area "Home"'),
    );

    final wet = await importThings(snapshot(), store: store, now: now);
    expect(
      wet.plan.ops.map((op) => op.describe()),
      dry.plan.ops.map((op) => op.describe()),
    );
  });

  test('an entity deleted in sai is left alone and counted', () async {
    final ids = seed();
    await importThings(snapshot(), store: store, now: now);
    final oat = store.projection.idByExternal('things3', ids.oat)!;
    await store.deleteTask(oat);
    final count = logLines().length;

    final result = await importThings(snapshot(), store: store, now: now);

    expect(result.plan.isEmpty, isTrue);
    expect(logLines().length, count);
    expect(result.report.unsupported[Unsupported.deletedInSai], 1);
  });

  test(
    'an area archived in sai is left alone; its contents import unfiled',
    () async {
      final ids = seed();
      await importThings(snapshot(), store: store, now: now);
      final home = store.projection.idByExternal('things3', ids.home)!;
      await store.archiveArea(home);
      final count = logLines().length;

      final result = await importThings(snapshot(), store: store, now: now);

      expect(result.report.unsupported[Unsupported.archivedInSai], 4);
      expect(logLines().length, count, reason: 'nothing else changed');
      expect(store.projection.areas[home]!.archivedAt, isNotNull);
    },
  );

  test('the import is an undo barrier', () async {
    seed();
    await store.createTask(title: 'mine');
    expect(store.canUndo, isTrue);

    await importThings(snapshot(), store: store, now: now);

    expect(store.canUndo, isFalse);
    expect(await store.undo(), isNull);
  });
}
