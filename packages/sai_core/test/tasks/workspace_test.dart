import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  const today = CalendarDate(2026, 8, 24);
  const todayList = ListSection(TaskList.today);

  late Directory tmp;
  late Archive archive;
  late TaskStore store;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sai_workspace_test');
    archive = await Archive.open(tmp);
    store = await TaskStore.open(archive, source: 'sai/tui');
  });

  tearDown(() async {
    store.dispose();
    await archive.close();
    tmp.deleteSync(recursive: true);
  });

  RestoredWorkspace restore({
    String? section,
    String? task,
    Iterable<String> collapsed = const [],
  }) => restoreWorkspace(
    store.projection,
    section: section,
    task: task,
    collapsedAreas: collapsed,
    today: today,
  );

  group('restoreWorkspace', () {
    test('nothing saved opens on Today', () {
      final r = restore();
      expect(r.section, todayList);
      expect(r.task, isNull);
      expect(r.collapsedAreas, isEmpty);
    });

    test('a live section of every kind comes back', () async {
      final area = await store.createArea(title: 'Home');
      final project = await store.createProject(title: 'Garden', area: area);
      final tag = await store.createTag(title: 'errand');
      for (final section in [
        const ListSection(TaskList.someday),
        const TrashSection(),
        AreaSection(area),
        ProjectSection(project),
        TagSection(tag),
      ]) {
        expect(
          restore(section: sectionKey(section)).section,
          section,
          reason: '$section',
        );
      }
    });

    test('an archived container stays browsable', () async {
      final project = await store.createProject(title: 'Attic');
      await store.archiveProject(project);
      expect(
        restore(section: sectionKey(ProjectSection(project))).section,
        ProjectSection(project),
      );
    });

    test('a deleted, unknown or unreadable section falls back to Today and '
        'drops the task', () async {
      final project = await store.createProject(title: 'Garden');
      final task = await store.createTask(title: 'dig', project: project);
      final key = sectionKey(ProjectSection(project));
      expect(restore(section: key, task: '$task').task, task);
      await store.deleteProject(project);
      for (final bad in [
        key,
        sectionKey(ProjectSection(BlobRef.sha256OfBytes([9]))),
        'project:nope',
        'yesterday',
        '',
      ]) {
        final r = restore(section: bad, task: '$task');
        expect(r.section, todayList, reason: bad);
        expect(r.task, isNull, reason: bad);
      }
    });

    test('the task is kept only while the section shows it', () async {
      final project = await store.createProject(title: 'Garden');
      final task = await store.createTask(title: 'dig', project: project);
      final key = sectionKey(ProjectSection(project));
      expect(restore(section: key, task: '$task').task, task);
      expect(restore(section: 'list:inbox', task: '$task').task, isNull);
      expect(restore(section: key, task: 'sha256-zz').task, isNull);
      expect(restore(section: key, task: '').task, isNull);
      await store.completeTask(task);
      expect(restore(section: key, task: '$task').task, isNull);
      expect(restore(section: 'list:logbook', task: '$task').task, task);
      await store.deleteTask(task);
      expect(restore(section: 'list:logbook', task: '$task').task, isNull);
      expect(restore(section: 'trash', task: '$task').task, task);
    });

    test('collapsed areas keep only live ids', () async {
      final home = await store.createArea(title: 'Home');
      final gone = await store.createArea(title: 'Gone');
      await store.deleteArea(gone);
      final parked = await store.createArea(title: 'Parked');
      await store.archiveArea(parked);
      final r = restore(
        collapsed: ['$home', '$gone', '$parked', 'nonsense', ''],
      );
      expect(r.collapsedAreas, {home, parked});
    });
  });
}
