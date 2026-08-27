import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  const today = CalendarDate(2026, 8, 24);

  late Directory tmp;
  late Archive archive;
  late TaskStore store;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sai_find_test');
    archive = await Archive.open(tmp);
    store = await TaskStore.open(archive, source: 'sai/tui');
  });

  tearDown(() async {
    store.dispose();
    await archive.close();
    tmp.deleteSync(recursive: true);
  });

  List<FindResult> find(String query, {int limit = 25}) =>
      findInTasks(store.projection, query, today: today, limit: limit);

  group('findInTasks', () {
    test('an empty query offers the standard lists and the Trash', () async {
      await store.createArea(title: 'Work');
      final results = find('   ');
      expect(results.map((r) => r.title), [
        'Inbox',
        'Today',
        'Upcoming',
        'Anytime',
        'Someday',
        'Logbook',
        'Trash',
      ]);
      expect(results.first.section, const ListSection(TaskList.inbox));
      expect(results.last.section, const TrashSection());
      expect(results.last.kind, FindResultKind.trash);
    });

    test('covers every kind and lands each on its section', () async {
      final area = await store.createArea(title: 'Alpha area');
      final project = await store.createProject(
        title: 'Alpha project',
        area: area,
      );
      final heading = await store.createHeading(
        project: project,
        title: 'Alpha heading',
      );
      final tag = await store.createTag(title: 'alpha tag');
      final task = await store.createTask(
        title: 'Alpha task',
        project: project,
        heading: heading,
      );
      final results = find('alpha');
      expect(results.map((r) => r.kind), [
        FindResultKind.area,
        FindResultKind.project,
        FindResultKind.heading,
        FindResultKind.tag,
        FindResultKind.task,
      ]);
      expect(results[0].section, AreaSection(area));
      expect(results[1].section, ProjectSection(project));
      expect(results[2].section, ProjectSection(project));
      expect(results[2].detail, 'Alpha project');
      expect(results[3].section, TagSection(tag));
      expect(results[4].section, ProjectSection(project));
      expect(results[4].task, task);
      expect(results[4].detail, 'Alpha project');
      expect(results.take(4).every((r) => r.task == null), isTrue);
    });

    test('lists match by title too', () {
      expect(find('log').single.title, 'Logbook');
      expect(find('tra').single.section, const TrashSection());
    });

    test('ranks exact, prefix, word-prefix, then substring', () async {
      await store.createTask(title: 'report');
      await store.createTask(title: 'reporting tools');
      await store.createTask(title: 'annual report');
      await store.createTask(title: 'unreported');
      expect(find('report').map((r) => r.title), [
        'report',
        'reporting tools',
        'annual report',
        'unreported',
      ]);
    });

    test('folds case and diacritics both ways', () async {
      await store.createTask(title: 'Zażółć gęślą');
      await store.createTask(title: 'Café');
      expect(find('zazolc').single.title, 'Zażółć gęślą');
      expect(find('CAFÉ').single.title, 'Café');
      expect(find('cafe').single.title, 'Café');
    });

    test('leaves out deleted entities and marks archived containers', () async {
      final gone = await store.createProject(title: 'Old plan');
      await store.deleteProject(gone);
      final parked = await store.createProject(title: 'Old attic');
      await store.archiveProject(parked);
      final area = await store.createArea(title: 'Old area');
      await store.archiveArea(area);
      final tag = await store.createTag(title: 'old tag');
      await store.deleteTag(tag);
      final task = await store.createTask(title: 'old task');
      await store.deleteTask(task);
      final results = find('old');
      expect(results.map((r) => r.title), ['Old area', 'Old attic']);
      expect(results.every((r) => r.detail == 'Archived'), isTrue);
    });

    test('a completed task opens in the Logbook, not its project', () async {
      final project = await store.createProject(title: 'Garden');
      final done = await store.createTask(title: 'dig', project: project);
      await store.completeTask(done);
      final result = find('dig').single;
      expect(result.section, const ListSection(TaskList.logbook));
      expect(result.detail, 'Logbook');
    });

    test('a loose task opens in the list it lives in', () async {
      await store.quickCapture('Buy milk', today: today);
      await store.createTask(
        title: 'Buy plane tickets',
        when: const TaskWhen.date(CalendarDate(2026, 9, 1)),
      );
      final area = await store.createArea(title: 'Home');
      await store.createTask(title: 'Buy paint', area: area);
      final results = {for (final r in find('buy')) r.title: r};
      expect(results['Buy milk']!.section, const ListSection(TaskList.inbox));
      expect(results['Buy milk']!.detail, 'Inbox');
      expect(
        results['Buy plane tickets']!.section,
        const ListSection(TaskList.upcoming),
      );
      expect(results['Buy paint']!.section, AreaSection(area));
      expect(results['Buy paint']!.detail, 'Home');
    });

    test('caps the result count', () async {
      for (var i = 0; i < 30; i++) {
        await store.createTask(title: 'chore $i');
      }
      expect(find('chore', limit: 5), hasLength(5));
      expect(find('chore'), hasLength(25));
    });
  });
}
