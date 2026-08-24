import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  const today = CalendarDate(2026, 8, 24);

  late Directory tmp;
  late Archive archive;
  late TaskStore store;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sai_sidebar_test');
    archive = await Archive.open(tmp);
    store = await TaskStore.open(archive, source: 'sai/tui');
  });

  tearDown(() async {
    store.dispose();
    await archive.close();
    tmp.deleteSync(recursive: true);
  });

  SidebarModel model() => sidebarModel(store.projection, today: today);

  group('sidebarModel', () {
    test('an empty projection: six lists in enum order, then the Trash', () {
      final m = model();
      expect(m.lists.map((e) => e.label), [
        'Inbox (0)',
        'Today (0)',
        'Upcoming (0)',
        'Anytime (0)',
        'Someday (0)',
        'Logbook (0)',
      ]);
      expect(m.trash.label, 'Trash (0)');
      expect(m.areas, isEmpty);
      expect(m.projects, isEmpty);
      expect(m.rows, hasLength(7));
      expect(
        m.lists.map((e) => e.section),
        TaskList.values.map(ListSection.new),
      );
      expect(m.trash.section, const TrashSection());
    });

    test('list counts follow the view unions', () async {
      await store.quickCapture('Pay rent !tomorrow', today: today);
      final m = model();
      final byTitle = {for (final e in m.lists) e.title: e.count};
      expect(byTitle['Inbox'], 1);
      expect(byTitle['Upcoming'], 1);
      expect(byTitle['Today'], 0);
    });

    test('the Trash counts deleted tasks', () async {
      final id = await store.createTask(title: 'oops');
      await store.deleteTask(id);
      final m = model();
      expect(m.trash.count, 1);
      final byTitle = {for (final e in m.lists) e.title: e.count};
      expect(byTitle['Inbox'], 0);
    });

    test('areas sort by title case-insensitively, ties broken by id', () async {
      await store.createArea(title: 'work');
      await store.createArea(title: 'Family');
      final homeA = await store.createArea(title: 'Home');
      final homeB = await store.createArea(title: 'home');
      final m = model();
      expect(m.areas.map((a) => a.entry.title).toList().sublist(0, 1), [
        'Family',
      ]);
      expect(m.areas.last.entry.title, 'work');
      final homes = m.areas.sublist(1, 3).map((a) => a.entry.section).toList();
      final expected = [homeA, homeB]
        ..sort((a, b) => a.toString().compareTo(b.toString()));
      expect(homes, expected.map(AreaSection.new));
    });

    test('projects nest under their area in the same order', () async {
      final area = await store.createArea(title: 'Home');
      await store.createProject(title: 'renovate', area: area);
      await store.createProject(title: 'Garden', area: area);
      final m = model();
      expect(m.areas.single.entry.title, 'Home');
      expect(m.areas.single.projects.map((e) => e.title), [
        'Garden',
        'renovate',
      ]);
      expect(m.projects, isEmpty);
    });

    test('standalone projects come after the areas in rows', () async {
      final area = await store.createArea(title: 'Home');
      await store.createProject(title: 'Garden', area: area);
      await store.createProject(title: 'Album');
      final m = model();
      expect(m.projects.map((e) => e.title), ['Album']);
      expect(m.rows.map((e) => e.title).toList().sublist(7), [
        'Home',
        'Garden',
        'Album',
      ]);
    });

    test('deleted areas and projects disappear', () async {
      final area = await store.createArea(title: 'Home');
      final project = await store.createProject(title: 'Garden', area: area);
      final gone = await store.createProject(title: 'Album');
      await store.deleteProject(project);
      await store.deleteProject(gone);
      final m = model();
      expect(m.areas.single.projects, isEmpty);
      expect(m.projects, isEmpty);
      await store.deleteArea(area);
      expect(model().areas, isEmpty);
    });

    test('a project whose area was deleted shows as standalone', () async {
      final area = await store.createArea(title: 'Home');
      await store.createProject(title: 'Garden', area: area);
      await store.deleteArea(area);
      final m = model();
      expect(m.areas, isEmpty);
      expect(m.projects.map((e) => e.title), ['Garden']);
    });

    test('container counts are open, visible tasks', () async {
      final area = await store.createArea(title: 'Home');
      final project = await store.createProject(title: 'Garden', area: area);
      final done = await store.createTask(title: 'dig', project: project);
      await store.createTask(title: 'plant', project: project);
      await store.completeTask(done);
      await store.createTask(title: 'dust', area: area);
      final m = model();
      expect(m.areas.single.entry.count, 1);
      expect(m.areas.single.projects.single.count, 1);
    });
  });

  group('sectionTasks', () {
    test('dispatches to the right query for each section kind', () async {
      final area = await store.createArea(title: 'Home');
      final project = await store.createProject(title: 'Garden', area: area);
      await store.createTask(title: 'plant', project: project);
      await store.createTask(title: 'dust', area: area);
      await store.quickCapture('Buy oat milk', today: today);
      final trashed = await store.createTask(title: 'oops');
      await store.deleteTask(trashed);
      final p = store.projection;
      expect(
        sectionTasks(
          p,
          const ListSection(TaskList.inbox),
          today: today,
        ).map((t) => t.title),
        ['Buy oat milk'],
      );
      expect(
        sectionTasks(p, const TrashSection(), today: today).single.title,
        'oops',
      );
      expect(
        sectionTasks(p, AreaSection(area), today: today).single.title,
        'dust',
      );
      expect(
        sectionTasks(p, ProjectSection(project), today: today).single.title,
        'plant',
      );
    });
  });

  group('sectionTitle', () {
    test('names every section kind', () async {
      final area = await store.createArea(title: 'Home');
      final project = await store.createProject(title: 'Garden', area: area);
      final p = store.projection;
      expect(sectionTitle(p, const ListSection(TaskList.today)), 'Today');
      expect(sectionTitle(p, const TrashSection()), 'Trash');
      expect(sectionTitle(p, AreaSection(area)), 'Home');
      expect(sectionTitle(p, ProjectSection(project)), 'Garden');
    });

    test('degrades for a container the projection does not know', () {
      final ghost = BlobRef.sha256OfBytes([1, 2, 3]);
      expect(sectionTitle(store.projection, AreaSection(ghost)), '(deleted)');
      expect(
        sectionTitle(store.projection, ProjectSection(ghost)),
        '(deleted)',
      );
    });
  });

  group('SidebarSection equality', () {
    test('sections compare by meaning', () {
      final a = BlobRef.sha256OfBytes([1]);
      final b = BlobRef.sha256OfBytes([2]);
      expect(
        const ListSection(TaskList.inbox),
        const ListSection(TaskList.inbox),
      );
      expect(
        const ListSection(TaskList.inbox),
        isNot(const ListSection(TaskList.today)),
      );
      expect(const TrashSection(), const TrashSection());
      expect(AreaSection(a), AreaSection(a));
      expect(AreaSection(a), isNot(AreaSection(b)));
      expect(ProjectSection(a), ProjectSection(a));
      expect(ProjectSection(a), isNot(AreaSection(a)));
      expect({AreaSection(a), AreaSection(a), ProjectSection(a)}, hasLength(2));
    });
  });
}
