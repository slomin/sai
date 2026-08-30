import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

/// End-of-day retention (#97): a task finished on the current local day
/// stays in its working views under `FinishedTaskVisibility.endOfDay`,
/// and never counts.
void main() {
  const today = CalendarDate(2026, 8, 24);
  const endOfDay = FinishedTaskVisibility.endOfDay;
  const immediate = FinishedTaskVisibility.immediate;
  // Local instants: retention is judged in the host's zone, like the
  // Logbook's days.
  final thisMorning = DateTime(2026, 8, 24, 9, 30);
  final lastNight = DateTime(2026, 8, 23, 23, 59, 59);
  final created = DateTime.utc(2026, 8, 20);

  var counter = 0;
  Task task({
    DateTime? completedAt,
    DateTime? cancelledAt,
    DateTime? deletedAt,
    TaskWhen when = TaskWhen.none,
    CalendarDate? deadline,
    bool filed = false,
  }) => Task(
    id: BlobRef.sha256OfBytes([++counter]),
    title: 'case $counter',
    when: when,
    deadline: deadline,
    project: filed ? BlobRef.sha256OfBytes([9]) : null,
    createdAt: created,
    modifiedAt: created,
    completedAt: completedAt,
    cancelledAt: cancelledAt,
    deletedAt: deletedAt,
  );

  group('isRetained', () {
    test('finished on the local day, not deleted', () {
      expect(isRetained(task(completedAt: thisMorning), today), isTrue);
      expect(isRetained(task(cancelledAt: thisMorning), today), isTrue);
      expect(isRetained(task(completedAt: lastNight), today), isFalse);
      expect(isRetained(task(), today), isFalse, reason: 'open');
      expect(
        isRetained(
          task(completedAt: thisMorning, deletedAt: thisMorning),
          today,
        ),
        isFalse,
        reason: 'the Trash is not a working view',
      );
      // Cancelled after a completion: the cancellation is the finish.
      expect(
        isRetained(
          task(completedAt: lastNight, cancelledAt: thisMorning),
          today,
        ),
        isTrue,
      );
    });

    test('a UTC instant is judged by its local day', () {
      final finished = thisMorning.toUtc();
      expect(isRetained(task(completedAt: finished), today), isTrue);
      expect(
        isRetained(
          task(completedAt: finished),
          const CalendarDate(2026, 8, 25),
        ),
        isFalse,
      );
    });
  });

  group('listsOf under end-of-day', () {
    test('a retained task is in the Logbook and its as-if-open lists', () {
      final inbox = task(completedAt: thisMorning);
      expect(listsOf(inbox, today), {TaskList.logbook});
      expect(listsOf(inbox, today, visibility: immediate), {TaskList.logbook});
      expect(listsOf(inbox, today, visibility: endOfDay), {
        TaskList.logbook,
        TaskList.inbox,
      });
      final filedToday = task(
        cancelledAt: thisMorning,
        when: const TaskWhen.date(today),
        deadline: const CalendarDate(2026, 8, 30),
        filed: true,
      );
      expect(listsOf(filedToday, today, visibility: endOfDay), {
        TaskList.logbook,
        TaskList.today,
        TaskList.anytime,
        TaskList.upcoming,
      });
      expect(listOf(filedToday, today), TaskList.logbook, reason: 'partition');
    });

    test('yesterday\'s finish and a deleted task stay out', () {
      expect(
        listsOf(task(completedAt: lastNight), today, visibility: endOfDay),
        {TaskList.logbook},
      );
      expect(
        listsOf(
          task(completedAt: thisMorning, deletedAt: thisMorning),
          today,
          visibility: endOfDay,
        ),
        isEmpty,
      );
    });
  });

  group('the projection and the views', () {
    late Directory tmp;
    late Archive archive;
    late TaskStore store;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('sai_retention_test');
      archive = await Archive.open(tmp);
      store = await TaskStore.open(archive, source: 'sai/tui');
    });

    tearDown(() async {
      store.dispose();
      await archive.close();
      tmp.deleteSync(recursive: true);
    });

    TaskView view(
      SidebarSection section, [
      FinishedTaskVisibility visibility = endOfDay,
    ]) => taskView(
      store.projection,
      section,
      today: today,
      visibility: visibility,
    );
    List<String> titles(TaskView v) => [for (final t in v.tasks) t.title];

    test('Today and the Inbox keep a retained row at its position', () async {
      await store.quickCapture('One @today', today: today);
      final two = await store.quickCapture('Two @today', today: today);
      await store.quickCapture('Three @today', today: today);
      final loose = await store.quickCapture('Loose', today: today);
      await store.completeTask(two!, at: thisMorning);
      await store.cancelTask(loose!, at: thisMorning);
      const todayList = ListSection(TaskList.today);
      expect(titles(view(todayList)), ['One', 'Two', 'Three']);
      expect(titles(view(todayList, immediate)), ['One', 'Three']);
      expect(titles(view(const ListSection(TaskList.inbox))), ['Loose']);
      expect(
        titles(view(const ListSection(TaskList.inbox), immediate)),
        isEmpty,
      );
      // The Logbook has them at once, either way.
      for (final visibility in FinishedTaskVisibility.values) {
        expect(
          titles(view(const ListSection(TaskList.logbook), visibility)),
          unorderedEquals(['Two', 'Loose']),
        );
      }
      expect(
        store.projection.list(TaskList.today, today: today).map((t) => t.title),
        ['One', 'Three'],
        reason: 'the query defaults to open only',
      );
    });

    test('a finish before today is gone from the working views', () async {
      final one = await store.quickCapture('One @today', today: today);
      await store.completeTask(one!, at: lastNight);
      expect(titles(view(const ListSection(TaskList.today))), isEmpty);
      expect(titles(view(const ListSection(TaskList.logbook))), ['One']);
    });

    test(
      'project, heading, area, tag and the Anytime hierarchy keep it',
      () async {
        final area = await store.createArea(title: 'Home');
        final project = await store.createProject(title: 'Kitchen', area: area);
        final heading = await store.createHeading(
          project: project,
          title: 'Prep',
        );
        final tag = await store.createTag(title: 'errand');
        final direct = await store.createTask(title: 'Direct', area: area);
        final loose = await store.createTask(title: 'Loose', project: project);
        final under = await store.createTask(
          title: 'Under',
          project: project,
          heading: heading,
        );
        final tagged = await store.createTask(title: 'Tagged', tags: [tag]);
        for (final id in [direct, loose, under, tagged]) {
          await store.completeTask(id, at: thisMorning);
        }
        final proj = view(ProjectSection(project));
        expect(proj.sections.map((s) => s.tasks.map((t) => t.title).toList()), [
          ['Loose'],
          ['Under'],
        ]);
        expect(view(ProjectSection(project), immediate).tasks, isEmpty);
        expect(titles(view(AreaSection(area))), ['Direct', 'Loose', 'Under']);
        expect(titles(view(TagSection(tag))), ['Tagged']);
        expect(titles(view(TagSection(tag), immediate)), isEmpty);
        final anytime = view(const ListSection(TaskList.anytime));
        expect(titles(anytime), ['Direct', 'Loose', 'Under']);
        expect(
          view(const ListSection(TaskList.anytime), immediate).tasks,
          isEmpty,
        );
      },
    );

    test('Upcoming keeps a retained task on its day', () async {
      const soon = CalendarDate(2026, 8, 30);
      final id = await store.createTask(
        title: 'Soon',
        when: const TaskWhen.date(soon),
      );
      await store.completeTask(id, at: thisMorning);
      final upcoming = view(const ListSection(TaskList.upcoming));
      expect(upcoming.sections.single.day, soon);
      expect(titles(upcoming), ['Soon']);
      expect(
        view(const ListSection(TaskList.upcoming), immediate).tasks,
        isEmpty,
      );
    });

    test('counts never include a retained task', () async {
      final area = await store.createArea(title: 'Home');
      final project = await store.createProject(title: 'Kitchen', area: area);
      final one = await store.quickCapture('One @today', today: today);
      await store.quickCapture('Two @today', today: today);
      final filed = await store.createTask(title: 'Filed', project: project);
      await store.completeTask(one!, at: thisMorning);
      await store.cancelTask(filed, at: thisMorning);
      final m = sidebarModel(store.projection, today: today);
      final byTitle = {for (final e in m.lists) e.title: e.count};
      expect(byTitle['Today'], 1);
      expect(byTitle['Anytime'], 0);
      expect(byTitle['Logbook'], 2);
      expect(m.areas.single.projects.single.count, 0);
      // The assistant's context is open tasks only, whatever the setting.
      expect(
        taskContextFor(store.projection, today),
        'Today is 2026-08-24.\nToday (1):\n- Two @today\nUpcoming (0): none',
      );
      // The capture surface shows the row but counts only the open ones.
      final sections = captureSections(
        store.projection,
        today,
        visibility: endOfDay,
      );
      final todaySection = sections.singleWhere((s) => s.name == 'Today');
      expect(todaySection.tasks.map((t) => t.title), ['One', 'Two']);
      expect(todaySection.label, 'Today (1)');
      expect(
        captureSections(
          store.projection,
          today,
        ).singleWhere((s) => s.name == 'Today').tasks.map((t) => t.title),
        ['Two'],
      );
    });

    test('a retained row is reopened at its position, and a restored '
        'selection on it survives', () async {
      await store.quickCapture('One @today', today: today);
      final two = await store.quickCapture('Two @today', today: today);
      await store.quickCapture('Three @today', today: today);
      await store.completeTask(two!, at: thisMorning);
      const todayList = ListSection(TaskList.today);
      final restored = restoreWorkspace(
        store.projection,
        section: sectionKey(todayList),
        task: two.toString(),
        collapsedAreas: const [],
        today: today,
        visibility: endOfDay,
      );
      expect(restored.task, two);
      expect(
        restoreWorkspace(
          store.projection,
          section: sectionKey(todayList),
          task: two.toString(),
          collapsedAreas: const [],
          today: today,
        ).task,
        isNull,
        reason: 'not shown under immediate',
      );
      await store.reopenTask(two);
      expect(titles(view(todayList)), ['One', 'Two', 'Three']);
      expect(titles(view(todayList, immediate)), ['One', 'Two', 'Three']);
    });
  });

  group('taskViewProvider', () {
    TaskProjection finishedAt(DateTime instant) {
      final created = Event.seal(
        TaskCreated(
          title: 'done',
          when: const TaskWhen.date(today),
        ).toDraft(source: 'sai/test'),
        prev: null,
        ts: DateTime.utc(2026, 8, 24, 6),
      );
      final createdId = created.deriveId();
      var projection = TaskProjection.empty.apply(
        StoredEvent(id: createdId, event: created),
      );
      final completed = Event.seal(
        TaskCompleted(createdId).toDraft(source: 'sai/test'),
        prev: createdId,
        ts: instant.toUtc(),
      );
      return projection = projection.apply(
        StoredEvent(id: completed.deriveId(), event: completed),
      );
    }

    test('follows the setting', () {
      for (final (visibility, shown) in [(endOfDay, 1), (immediate, 0)]) {
        final container = ProviderContainer.test(
          overrides: [
            tasksProvider.overrideWithBuild(
              (ref, notifier) => finishedAt(thisMorning),
            ),
            clockProvider.overrideWithValue(() => thisMorning),
            finishedTaskVisibilityProvider.overrideWithValue(visibility),
          ],
        );
        expect(
          container
              .read(taskViewProvider(const ListSection(TaskList.today)))
              .requireValue
              .tasks,
          hasLength(shown),
          reason: '$visibility',
        );
        expect(
          container.read(sidebarProvider).requireValue.lists.first.count,
          0,
          reason: 'Inbox count stays open-only',
        );
      }
    });

    test('drops a retained row at local midnight with no mutation', () {
      fakeAsync((async) {
        final start = DateTime(2026, 8, 24, 23, 59);
        final container = ProviderContainer.test(
          overrides: [
            tasksProvider.overrideWithBuild(
              (ref, notifier) => finishedAt(start),
            ),
            clockProvider.overrideWithValue(() => start.add(async.elapsed)),
            finishedTaskVisibilityProvider.overrideWithValue(endOfDay),
          ],
        );
        const section = ListSection(TaskList.today);
        container.listen(taskViewProvider(section), (_, _) {});
        async.flushMicrotasks();
        expect(
          container.read(taskViewProvider(section)).requireValue.tasks,
          hasLength(1),
        );
        async.elapse(const Duration(minutes: 1));
        expect(
          container.read(taskViewProvider(section)).requireValue.tasks,
          isEmpty,
        );
        container.dispose();
      });
    });
  });
}
