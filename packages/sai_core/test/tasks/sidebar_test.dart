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

    test('areas follow the persisted order; creation appends', () async {
      await store.createArea(title: 'work');
      await store.createArea(title: 'Family');
      final home = await store.createArea(title: 'Home');
      expect(model().areas.map((a) => a.entry.title), [
        'work',
        'Family',
        'Home',
      ]);
      await store.reorderArea(home, after: null);
      expect(model().areas.map((a) => a.entry.title), [
        'Home',
        'work',
        'Family',
      ]);
    });

    test('projects nest under their area in the persisted order', () async {
      final area = await store.createArea(title: 'Home');
      final renovate = await store.createProject(title: 'renovate', area: area);
      await store.createProject(title: 'Garden', area: area);
      final m = model();
      expect(m.areas.single.entry.title, 'Home');
      expect(m.areas.single.projects.map((e) => e.title), [
        'renovate',
        'Garden',
      ]);
      expect(m.projects, isEmpty);
      await store.reorderProject(renovate, after: null);
      expect(model().areas.single.projects.map((e) => e.title), [
        'renovate',
        'Garden',
      ]);
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

    test('archived areas and projects move to the archived rows', () async {
      final area = await store.createArea(title: 'Home');
      final project = await store.createProject(title: 'Garden', area: area);
      await store.createTask(title: 'mow', project: project);
      await store.archiveProject(project);
      var m = model();
      expect(m.areas.single.projects, isEmpty);
      expect(m.archived.map((e) => e.label), ['Garden (1)']);
      await store.archiveArea(area);
      m = model();
      expect(m.areas, isEmpty);
      expect(m.archived.map((e) => e.title), ['Home', 'Garden']);
      expect(sectionTitle(store.projection, AreaSection(area)), 'Home');
      expect(
        sectionTasks(
          store.projection,
          ProjectSection(project),
          today: today,
        ).map((t) => t.title),
        ['mow'],
      );
    });

    test('a project whose area is archived shows as standalone', () async {
      final area = await store.createArea(title: 'Home');
      await store.createProject(title: 'Garden', area: area);
      await store.archiveArea(area);
      final m = model();
      expect(m.areas, isEmpty);
      expect(m.projects.map((e) => e.title), ['Garden']);
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

    test(
      'a tag section lists the open, visible tasks carrying the tag',
      () async {
        final tag = await store.createTag(title: 'errand');
        final project = await store.createProject(title: 'Garden');
        await store.createTask(title: 'plant', project: project, tags: [tag]);
        final done = await store.createTask(title: 'dig', tags: [tag]);
        await store.completeTask(done);
        await store.createTask(title: 'untagged');
        final parked = await store.createProject(title: 'Attic');
        await store.createTask(
          title: 'sort boxes',
          project: parked,
          tags: [tag],
        );
        await store.archiveProject(parked);
        expect(
          sectionTasks(
            store.projection,
            TagSection(tag),
            today: today,
          ).map((t) => t.title),
          ['plant'],
        );
      },
    );
  });

  group('section keys', () {
    test('every section kind round-trips through its key', () {
      final id = BlobRef.sha256OfBytes([7]);
      final sections = [
        for (final list in TaskList.values) ListSection(list),
        const TrashSection(),
        AreaSection(id),
        ProjectSection(id),
        TagSection(id),
      ];
      for (final section in sections) {
        expect(
          sectionFromKey(sectionKey(section)),
          section,
          reason: '$section',
        );
      }
      expect(sectionKey(const ListSection(TaskList.today)), 'list:today');
      expect(sectionKey(const TrashSection()), 'trash');
      expect(sectionKey(TagSection(id)), 'tag:$id');
    });

    test('a key this sai does not understand reads as nothing', () {
      for (final bad in [
        '',
        'today',
        'list:',
        'list:tomorrow',
        'area:',
        'area:not-a-ref',
        'project:sha256-abc',
        'heading:${BlobRef.sha256OfBytes([1])}',
        'trash:extra',
      ]) {
        expect(sectionFromKey(bad), isNull, reason: bad);
      }
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
      final tag = await store.createTag(title: 'errand');
      expect(sectionTitle(store.projection, TagSection(tag)), 'errand');
    });

    test('a deleted tag reads as gone', () async {
      final tag = await store.createTag(title: 'errand');
      await store.deleteTag(tag);
      expect(sectionTitle(store.projection, TagSection(tag)), '(deleted)');
    });

    test('a deleted container reads as gone', () async {
      final area = await store.createArea(title: 'Home');
      final project = await store.createProject(title: 'Garden', area: area);
      await store.deleteProject(project);
      await store.deleteArea(area);
      final p = store.projection;
      expect(sectionTitle(p, AreaSection(area)), '(deleted)');
      expect(sectionTitle(p, ProjectSection(project)), '(deleted)');
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
      expect(TagSection(a), TagSection(a));
      expect(TagSection(a), isNot(TagSection(b)));
      expect(TagSection(a), isNot(AreaSection(a)));
      expect(ProjectSection(a), ProjectSection(a));
      expect(ProjectSection(a), isNot(AreaSection(a)));
      expect({AreaSection(a), AreaSection(a), ProjectSection(a)}, hasLength(2));
    });
  });
}
