import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

import 'package:sai_core/things_testing.dart';

/// A fixture that exercises every mapping row once.
final class Scene {
  Scene(this.f) {
    home = f.area('Home');
    hidden = f.area('Archive', visible: false);
    errand = f.tag('errand', shortcut: 'e');
    urgent = f.tag('urgent', parent: errand);
    kitchen = f.project(
      'Kitchen',
      area: home,
      start: 1,
      notes: 'renovate',
      created: DateTime.utc(2024, 3, 1, 9),
    );
    shopping = f.heading('Shopping', project: kitchen);
    oatMilk = f.item(
      'Buy oat milk',
      start: 1,
      startDate: const CalendarDate(2026, 8, 24),
      deadline: const CalendarDate(2026, 8, 30),
      heading: shopping,
      project: kitchen,
      notes: 'the blue one',
      created: DateTime.utc(2024, 3, 2, 9),
    );
    f.tagTask(oatMilk, errand);
    f.tagTask(oatMilk, urgent);
    f.checklist(oatMilk, 'oat', status: 3, stopped: DateTime.utc(2026, 8, 25));
    f.checklist(oatMilk, 'milk');
    done = f.item(
      'Paint wall',
      project: kitchen,
      status: 3,
      stopped: DateTime.utc(2026, 8, 20, 8),
      created: DateTime.utc(2024, 3, 3, 9),
    );
    dropped = f.item(
      'Buy tiles',
      project: kitchen,
      status: 2,
      stopped: DateTime.utc(2026, 8, 21, 8),
    );
    someday = f.item('Learn piano', start: 2, area: home);
    inbox = f.item('Call mom');
    anytimeUnfiled = f.item('Read', start: 1, reminderTime: 3);
    template = f.item('Water plants', template: true, start: 1);
    instance = f.item(
      'Water plants',
      start: 1,
      startDate: const CalendarDate(2026, 8, 27),
      repeatingTemplate: template,
    );
    trashed = f.item('Old', trashed: true);
    finished = f.project('Move house', status: 3);
    inFinished = f.item('Pack boxes', project: finished, status: 3);
    f.heading('Boxes', project: finished);
    f.tagArea(home, errand);
    f.close();
  }

  final ThingsFixture f;
  late final String home,
      hidden,
      errand,
      urgent,
      kitchen,
      shopping,
      oatMilk,
      done,
      dropped,
      someday,
      inbox,
      anytimeUnfiled,
      template,
      instance,
      trashed,
      finished,
      inFinished;
}

void main() {
  late Directory tmp;
  final now = DateTime.utc(2026, 8, 26, 12);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_things_mapping_test');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  ThingsSnapshot snapshotOf(void Function(ThingsFixture) build) {
    final path = p.join(tmp.path, 'main.sqlite');
    final f = ThingsFixture(path);
    build(f);
    final db = ThingsDatabase.snapshot(path);
    addTearDown(db.dispose);
    return db.read();
  }

  test('an empty projection gets a create for every live entity, in order', () {
    late Scene s;
    final snapshot = snapshotOf((f) => s = Scene(f));
    final (plan, report) = planThingsImport(
      snapshot,
      projection: TaskProjection.empty,
      now: now,
    );

    expect(plan.ops.map((op) => (op.runtimeType, op.uuid)), [
      (CreateArea, s.home),
      (CreateArea, s.hidden),
      (CreateTag, s.errand),
      (CreateTag, s.urgent),
      (CreateProject, s.kitchen),
      (CreateHeading, s.shopping),
      (CreateTask, s.oatMilk),
      (CreateTask, s.done),
      (CreateTask, s.dropped),
      (CreateTask, s.someday),
      (CreateTask, s.inbox),
      (CreateTask, s.anytimeUnfiled),
      (CreateTask, s.instance),
    ]);

    final urgent = plan.ops[3] as CreateTag;
    expect(urgent.parent, s.errand);

    final kitchen = plan.ops[4] as CreateProject;
    expect(kitchen.area, s.home);
    expect(kitchen.notes, 'renovate');
    expect(kitchen.when, TaskWhen.none);
    expect(kitchen.createdAt, DateTime.utc(2024, 3, 1, 9));

    final oat = plan.ops[6] as CreateTask;
    expect(oat.placement.project, s.kitchen);
    expect(oat.placement.heading, s.shopping);
    expect(oat.placement.area, isNull);
    expect(oat.when, TaskWhen.date(const CalendarDate(2026, 8, 24)));
    expect(oat.deadline, const CalendarDate(2026, 8, 30));
    expect(oat.tags, [s.errand, s.urgent]);
    expect(oat.checklist.map((c) => (c.title, c.completedAt)), [
      ('oat', DateTime.utc(2026, 8, 25)),
      ('milk', null),
    ]);
    expect(oat.status.isOpen, isTrue);
    expect(oat.instance, isNull);
    expect(oat.describe(), '+ task "Buy oat milk" (${s.oatMilk})');

    final done = plan.ops[7] as CreateTask;
    expect(done.status.kind, ImportStatusKind.completed);
    expect(done.status.at, DateTime.utc(2026, 8, 20, 8));
    final dropped = plan.ops[8] as CreateTask;
    expect(dropped.status.kind, ImportStatusKind.cancelled);
    expect(dropped.status.at, DateTime.utc(2026, 8, 21, 8));
    final someday = plan.ops[9] as CreateTask;
    expect(someday.when, TaskWhen.someday);
    expect(someday.placement.area, s.home);
    final inbox = plan.ops[10] as CreateTask;
    expect(inbox.when, TaskWhen.none);
    expect(inbox.placement.area, isNull);
    final instance = plan.ops[12] as CreateTask;
    expect(instance.instance, s.template);

    expect(report.areas, isA<KindCounts>().having((c) => c.created, 'c', 2));
    expect(report.tags.created, 2);
    expect(report.projects.created, 1);
    expect(report.headings.created, 1);
    expect(report.tasks.created, 7);
    expect(report.unsupported, {
      Unsupported.areaTags: 1,
      Unsupported.tagShortcuts: 1,
      Unsupported.reminders: 1,
      Unsupported.anytimeUnfiled: 1,
      Unsupported.repeatingTemplates: 1,
      Unsupported.trashed: 1,
      Unsupported.finishedProjects: 1,
      Unsupported.inFinishedProjects: 2,
    });
    expect(report.render(), [
      'imported',
      '  areas: 2 created, 0 updated, 0 unchanged',
      '  tags: 2 created, 0 updated, 0 unchanged',
      '  projects: 1 created, 0 updated, 0 unchanged',
      '  headings: 1 created, 0 updated, 0 unchanged',
      '  tasks: 7 created, 0 updated, 0 unchanged',
      'not imported',
      '  ${Unsupported.areaTags}: 1',
      '  ${Unsupported.tagShortcuts}: 1',
      '  ${Unsupported.finishedProjects}: 1',
      '  ${Unsupported.inFinishedProjects}: 2',
      '  ${Unsupported.reminders}: 1',
      '  ${Unsupported.anytimeUnfiled}: 1',
      '  ${Unsupported.repeatingTemplates}: 1',
      '  ${Unsupported.trashed}: 1',
      'notes',
      ...report.notes.map((n) => '  $n'),
    ]);
  });

  test('a dropped heading falls back to the project; a missing parent to '
      'nowhere', () {
    late String live, task, orphan;
    final snapshot = snapshotOf((f) {
      live = f.project('P', start: 1);
      final gone = f.heading('H', project: live, trashed: true);
      task = f.item('under a trashed heading', project: live, heading: gone);
      orphan = f.item('in a missing project', project: 'project-404');
      f.close();
    });
    final (plan, report) = planThingsImport(
      snapshot,
      projection: TaskProjection.empty,
      now: now,
    );
    final byUuid = {for (final op in plan.ops) op.uuid: op};
    final t = byUuid[task] as CreateTask;
    expect(t.placement.project, live);
    expect(t.placement.heading, isNull);
    final o = byUuid[orphan] as CreateTask;
    expect(o.placement.project, isNull);
    expect(report.unsupported[Unsupported.trashed], 1);
    expect(report.unsupported[Unsupported.danglingParents], 1);
  });

  test('a repeating template project and its contents are reported', () {
    late String template, child, heading;
    final snapshot = snapshotOf((f) {
      template = f.project('Weekly review', start: 1);
      f.db.execute('update TMTask set rt1_recurrenceRule = ? where uuid = ?', [
        [1, 2, 3],
        template,
      ]);
      heading = f.heading('Steps', project: template);
      child = f.item('Clear inbox', project: template, heading: heading);
      f.close();
    });
    final (plan, report) = planThingsImport(
      snapshot,
      projection: TaskProjection.empty,
      now: now,
    );
    expect(plan.ops.map((op) => op.uuid), isNot(contains(template)));
    expect(plan.ops.map((op) => op.uuid), isNot(contains(child)));
    expect(plan.ops, isEmpty);
    expect(report.unsupported[Unsupported.repeatingTemplates], 1);
    expect(report.unsupported[Unsupported.inTemplateProjects], 2);
  });

  group('options leave history behind', () {
    late String openPlain, openInstance, doneOld, doneNew, doneInstance;
    ThingsSnapshot build() => snapshotOf((f) {
      final template = f.item('Water plants', template: true, start: 1);
      openPlain = f.item('Call mom');
      openInstance = f.item('Water plants', repeatingTemplate: template);
      doneOld = f.item(
        'Old chore',
        status: 3,
        stopped: DateTime.utc(2025, 12, 31, 12),
      );
      doneNew = f.item(
        'New chore',
        status: 2,
        stopped: DateTime.utc(2026, 8, 20, 12),
      );
      doneInstance = f.item(
        'Water plants',
        status: 3,
        stopped: DateTime.utc(2026, 8, 1, 12),
        repeatingTemplate: template,
      );
      f.close();
    });
    Set<String> imported(ThingsImportOptions options) {
      final (plan, _) = planThingsImport(
        build(),
        projection: TaskProjection.empty,
        now: now,
        options: options,
      );
      return plan.ops.map((op) => op.uuid).toSet();
    }

    test('nothing is left behind by default', () {
      expect(imported(const ThingsImportOptions()), {
        openPlain,
        openInstance,
        doneOld,
        doneNew,
        doneInstance,
      });
    });

    test('--open-only keeps the open ones, instances included', () {
      final (plan, report) = planThingsImport(
        build(),
        projection: TaskProjection.empty,
        now: now,
        options: const ThingsImportOptions(openOnly: true),
      );
      expect(plan.ops.map((op) => op.uuid), [openPlain, openInstance]);
      expect(report.unsupported[Unsupported.openOnly], 3);
      expect(report.tasks.created, 2);
    });

    test('--skip-repeat-history drops finished instances only', () {
      expect(imported(const ThingsImportOptions(skipRepeatHistory: true)), {
        openPlain,
        openInstance,
        doneOld,
        doneNew,
      });
    });

    test('--logbook-since drops what finished before the day', () {
      final since = const CalendarDate(2026, 1, 1);
      final (plan, report) = planThingsImport(
        build(),
        projection: TaskProjection.empty,
        now: now,
        options: ThingsImportOptions(logbookSince: since),
      );
      expect(plan.ops.map((op) => op.uuid).toSet(), {
        openPlain,
        openInstance,
        doneNew,
        doneInstance,
      });
      expect(report.unsupported[Unsupported.logbookBefore(since)], 1);
    });

    test('the options combine', () {
      expect(
        imported(
          const ThingsImportOptions(
            skipRepeatHistory: true,
            logbookSince: CalendarDate(2026, 1, 1),
          ),
        ),
        {openPlain, openInstance, doneNew},
      );
    });
  });

  test('an empty title becomes "(untitled)" and is counted', () {
    late String task, area;
    final snapshot = snapshotOf((f) {
      area = f.area('');
      task = f.item('', area: area);
      f.checklist(task, '');
      f.close();
    });
    final (plan, report) = planThingsImport(
      snapshot,
      projection: TaskProjection.empty,
      now: now,
    );
    final byUuid = {for (final op in plan.ops) op.uuid: op};
    expect((byUuid[area] as CreateArea).title, Unsupported.untitled);
    final t = byUuid[task] as CreateTask;
    expect(t.title, Unsupported.untitled);
    expect(t.checklist.single.title, Unsupported.untitled);
    expect(report.unsupported[Unsupported.emptyTitles], 3);
  });

  test('a future instant and an unreadable day are dropped and counted', () {
    late String task;
    final snapshot = snapshotOf((f) {
      task = f.item(
        'from the future',
        created: DateTime.utc(2030),
        status: 3,
        stopped: DateTime.utc(2031),
      );
      f.db.execute('update TMTask set deadline = ? where uuid = ?', [
        encodeThingsDay(const CalendarDate(2026, 2, 28)) + (2 << 7),
        task,
      ]);
      f.close();
    });
    final (plan, report) = planThingsImport(
      snapshot,
      projection: TaskProjection.empty,
      now: now,
    );
    final op = plan.ops.single as CreateTask;
    expect(op.createdAt, isNull);
    expect(op.status.kind, ImportStatusKind.completed);
    expect(op.status.at, isNull);
    expect(op.deadline, isNull);
    expect(report.unsupported[Unsupported.futureInstants], 2);
    expect(report.unsupported[Unsupported.badDates], 1);
  });
}
