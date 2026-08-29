import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  const today = CalendarDate(2026, 8, 24);
  const inbox = ListSection(TaskList.inbox);
  const todayList = ListSection(TaskList.today);
  const trash = TrashSection();

  late Directory tmp;
  late Archive archive;
  late TaskStore store;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sai_navigation_test');
    archive = await Archive.open(tmp);
    store = await TaskStore.open(archive, source: 'sai/tui');
  });

  tearDown(() async {
    store.dispose();
    await archive.close();
    tmp.deleteSync(recursive: true);
  });

  SidebarModel model() => sidebarModel(store.projection, today: today);

  List<String> titles(List<SidebarEntry> rows) => [
    for (final r in rows) r.title,
  ];

  group('visibleSidebarRows', () {
    test('lists, Trash, areas with their projects, loose, archived', () async {
      final home = await store.createArea(title: 'Home');
      await store.createProject(title: 'Garden', area: home);
      await store.createProject(title: 'Kitchen', area: home);
      await store.createProject(title: 'Solo');
      final old = await store.createProject(title: 'Old');
      await store.archiveProject(old);
      expect(titles(visibleSidebarRows(model(), const {})), [
        'Inbox',
        'Today',
        'Upcoming',
        'Anytime',
        'Someday',
        'Logbook',
        'Trash',
        'Home',
        'Garden',
        'Kitchen',
        'Solo',
        'Old',
      ]);
    });

    test('a folded area hides its projects, not itself', () async {
      final home = await store.createArea(title: 'Home');
      await store.createProject(title: 'Garden', area: home);
      final work = await store.createArea(title: 'Work');
      await store.createProject(title: 'Deck', area: work);
      final rows = visibleSidebarRows(model(), {home});
      expect(titles(rows).sublist(7), ['Home', 'Work', 'Deck']);
    });
  });

  group('stepSection', () {
    test('down and up walk the rows and stop at the ends', () async {
      await store.createArea(title: 'Home');
      final m = model();
      SidebarSection? step(SidebarSection from, NavDirection d) =>
          stepSection(m, const {}, from, d);
      expect(step(inbox, NavDirection.down), todayList);
      expect(step(inbox, NavDirection.up), inbox);
      final last = visibleSidebarRows(m, const {}).last.section;
      expect(step(last, NavDirection.down), last);
      expect(step(trash, NavDirection.down), last);
    });

    test('a section with no row starts from the top or the bottom', () async {
      final tag = await store.createTag(title: 'errand');
      final m = model();
      expect(
        stepSection(m, const {}, TagSection(tag), NavDirection.down),
        inbox,
      );
      expect(stepSection(m, const {}, TagSection(tag), NavDirection.up), trash);
    });

    test('a project folded away steps from its area', () async {
      final home = await store.createArea(title: 'Home');
      final garden = await store.createProject(title: 'Garden', area: home);
      await store.createProject(title: 'Solo');
      final m = model();
      expect(
        stepSection(m, {home}, ProjectSection(garden), NavDirection.down),
        m.projects.single.section,
        reason: 'the row after Home',
      );
      expect(
        stepSection(m, {home}, ProjectSection(garden), NavDirection.up),
        trash,
      );
      expect(
        stepSection(m, const {}, ProjectSection(garden), NavDirection.up),
        AreaSection(home),
        reason: 'unfolded: its own row',
      );
    });

    test('left and right are not steps', () {
      final m = model();
      expect(stepSection(m, const {}, inbox, NavDirection.left), isNull);
      expect(stepSection(m, const {}, inbox, NavDirection.right), isNull);
    });
  });

  group('foldable', () {
    test(
      'a live area is; an archived one, a project, a list are not',
      () async {
        final home = await store.createArea(title: 'Home');
        final old = await store.createArea(title: 'Old');
        await store.archiveArea(old);
        final project = await store.createProject(title: 'Solo');
        final m = model();
        expect(foldable(m, AreaSection(home)), isTrue);
        expect(foldable(m, AreaSection(old)), isFalse);
        expect(foldable(m, ProjectSection(project)), isFalse);
        expect(foldable(m, inbox), isFalse);
      },
    );
  });

  group('stepTask', () {
    test('walks the view across headings and stops at the ends', () async {
      final project = await store.createProject(title: 'Garden');
      final a = await store.createTask(title: 'a', project: project);
      final heading = await store.createHeading(
        project: project,
        title: 'Beds',
      );
      final b = await store.createTask(
        title: 'b',
        project: project,
        heading: heading,
      );
      final view = taskView(
        store.projection,
        ProjectSection(project),
        today: today,
      );
      expect(view.sections.length, 2, reason: 'a heading splits the view');
      final tasks = view.tasks;
      expect(stepTask(tasks, a, NavDirection.down), b);
      expect(stepTask(tasks, b, NavDirection.down), b);
      expect(stepTask(tasks, b, NavDirection.up), a);
      expect(stepTask(tasks, a, NavDirection.up), a);
    });

    test('nothing selected enters at the first or the last row', () async {
      final a = await store.createTask(title: 'a');
      final b = await store.createTask(title: 'b');
      final tasks = taskView(store.projection, inbox, today: today).tasks;
      expect(stepTask(tasks, null, NavDirection.down), a);
      expect(stepTask(tasks, null, NavDirection.up), b);
      expect(stepTask(tasks, null, NavDirection.right), a);
    });

    test('a selection that left the view steps from where it was', () async {
      final a = await store.createTask(title: 'a');
      final b = await store.createTask(title: 'b');
      final c = await store.createTask(title: 'c');
      await store.completeTask(b);
      final tasks = taskView(store.projection, inbox, today: today).tasks;
      expect(tasks, [isA<Task>(), isA<Task>()]);
      // b stood at index 1; c took its place.
      expect(stepTask(tasks, b, NavDirection.down, lastIndex: 1), c);
      expect(stepTask(tasks, b, NavDirection.up, lastIndex: 1), a);
      // Without a memory of where, from the top.
      expect(stepTask(tasks, b, NavDirection.down), a);
      // A remembered index past the end lands on the last row.
      expect(stepTask(tasks, b, NavDirection.down, lastIndex: 7), c);
      expect(stepTask(tasks, b, NavDirection.up, lastIndex: 0), a);
    });

    test('an empty list has nowhere to go', () {
      expect(stepTask(const [], null, NavDirection.down), isNull);
      expect(stepTask(const [], null, NavDirection.up), isNull);
    });
  });

  group('neighbourOf', () {
    test('the next row, else the one above, else nothing', () async {
      final a = await store.createTask(title: 'a');
      final b = await store.createTask(title: 'b');
      final c = await store.createTask(title: 'c');
      final tasks = taskView(store.projection, inbox, today: today).tasks;
      expect(neighbourOf(tasks, a), b);
      expect(neighbourOf(tasks, c), b);
      expect(neighbourOf([tasks.first], a), isNull);
      expect(neighbourOf(tasks, BlobRef.sha256OfBytes([9])), isNull);
    });
  });
}
