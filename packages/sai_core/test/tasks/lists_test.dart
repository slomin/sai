import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  const today = CalendarDate(2026, 8, 24);
  const yesterday = CalendarDate(2026, 8, 23);
  const tomorrow = CalendarDate(2026, 8, 25);
  final created = DateTime.utc(2026, 8, 20);
  final projectId = BlobRef.sha256OfBytes([9]);

  var counter = 0;
  Task task({
    TaskWhen when = TaskWhen.none,
    CalendarDate? deadline,
    bool filed = false,
    bool completed = false,
    bool cancelled = false,
    bool deleted = false,
  }) => Task(
    id: BlobRef.sha256OfBytes([++counter]),
    title: 'case $counter',
    when: when,
    deadline: deadline,
    project: filed ? projectId : null,
    createdAt: created,
    modifiedAt: created,
    completedAt: completed ? created : null,
    cancelledAt: cancelled ? created : null,
    deletedAt: deleted ? created : null,
  );

  group('listOf — the normative partition', () {
    test('the truth table', () {
      final cases = <(Task, TaskList?)>[
        // deleted wins over everything
        (task(deleted: true, when: TaskWhen.date(today)), null),
        // completed or cancelled → logbook, whatever else is set
        (task(completed: true), TaskList.logbook),
        (task(cancelled: true), TaskList.logbook),
        (
          task(completed: true, when: TaskWhen.date(tomorrow)),
          TaskList.logbook,
        ),
        (task(cancelled: true, deadline: yesterday), TaskList.logbook),
        // due (or overdue) deadline → today, even from Someday
        (task(deadline: today, filed: true), TaskList.today),
        (task(deadline: yesterday), TaskList.today),
        (task(when: TaskWhen.someday, deadline: today), TaskList.today),
        (task(when: TaskWhen.someday, deadline: yesterday), TaskList.today),
        // when-date arrived → today (an unfiled one leaves the Inbox)
        (task(when: TaskWhen.date(today)), TaskList.today),
        (task(when: TaskWhen.date(yesterday)), TaskList.today),
        (task(when: TaskWhen.date(today), filed: true), TaskList.today),
        // someday (with no due deadline) stays someday
        (task(when: TaskWhen.someday), TaskList.someday),
        (task(when: TaskWhen.someday, filed: true), TaskList.someday),
        (task(when: TaskWhen.someday, deadline: tomorrow), TaskList.someday),
        // future when-date → upcoming
        (task(when: TaskWhen.date(tomorrow)), TaskList.upcoming),
        (task(when: TaskWhen.date(tomorrow), filed: true), TaskList.upcoming),
        // no when: unfiled → inbox, filed → anytime
        (task(), TaskList.inbox),
        (task(deadline: tomorrow), TaskList.inbox),
        (task(filed: true), TaskList.anytime),
        (task(filed: true, deadline: tomorrow), TaskList.anytime),
      ];
      for (final (item, expected) in cases) {
        expect(listOf(item, today), expected, reason: item.title);
      }
    });

    test('area or heading placement counts as filed', () {
      final inArea = Task(
        id: BlobRef.sha256OfBytes([100]),
        title: 'in area',
        area: BlobRef.sha256OfBytes([101]),
        createdAt: created,
        modifiedAt: created,
      );
      expect(listOf(inArea, today), TaskList.anytime);
    });

    test('the boundary moves with today, not with the task', () {
      final item = task(when: TaskWhen.date(today));
      expect(listOf(item, yesterday), TaskList.upcoming);
      expect(listOf(item, today), TaskList.today);
      expect(listOf(item, tomorrow), TaskList.today);
    });

    test('is pure: same inputs, same answer', () {
      final item = task(when: TaskWhen.date(today), deadline: tomorrow);
      expect(listOf(item, today), listOf(item, today));
      expect(listsOf(item, today), listsOf(item, today));
    });
  });

  group('listsOf — the view unions', () {
    test('a filed Today task is also in Anytime', () {
      expect(listsOf(task(when: TaskWhen.date(today), filed: true), today), {
        TaskList.today,
        TaskList.anytime,
      });
    });

    test('an unfiled Today task is only in Today', () {
      expect(listsOf(task(when: TaskWhen.date(today)), today), {
        TaskList.today,
      });
    });

    test('any open task with a future deadline surfaces in Upcoming', () {
      expect(listsOf(task(filed: true, deadline: tomorrow), today), {
        TaskList.anytime,
        TaskList.upcoming,
      });
      expect(listsOf(task(deadline: tomorrow), today), {
        TaskList.inbox,
        TaskList.upcoming,
      });
      expect(listsOf(task(when: TaskWhen.someday, deadline: tomorrow), today), {
        TaskList.someday,
        TaskList.upcoming,
      });
      expect(
        listsOf(task(when: TaskWhen.date(today), deadline: tomorrow), today),
        {TaskList.today, TaskList.upcoming},
      );
      // A finished task surfaces nowhere but the Logbook.
      expect(listsOf(task(completed: true, deadline: tomorrow), today), {
        TaskList.logbook,
      });
    });

    test('logbook, someday and deleted stay single (or empty)', () {
      expect(listsOf(task(completed: true), today), {TaskList.logbook});
      expect(listsOf(task(when: TaskWhen.someday), today), {TaskList.someday});
      expect(listsOf(task(deleted: true), today), isEmpty);
    });
  });

  group('listTitle — the display names', () {
    test('covers every list', () {
      expect(listTitle(TaskList.inbox), 'Inbox');
      expect(listTitle(TaskList.today), 'Today');
      expect(listTitle(TaskList.upcoming), 'Upcoming');
      expect(listTitle(TaskList.anytime), 'Anytime');
      expect(listTitle(TaskList.someday), 'Someday');
      expect(listTitle(TaskList.logbook), 'Logbook');
    });

    test('the Trash keeps its name beside the lists', () {
      expect(trashTitle, 'Trash');
    });
  });

  group('TaskView', () {
    late Directory tmp;
    late Archive archive;
    late TaskStore store;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('sai_task_view_test');
      archive = await Archive.open(tmp);
      store = await TaskStore.open(archive, source: 'sai/tui');
    });

    tearDown(() async {
      store.dispose();
      await archive.close();
      tmp.deleteSync(recursive: true);
    });

    TaskView view(SidebarSection section) =>
        taskView(store.projection, section, today: today);

    test(
      'Inbox and Today are flat and keep their independent orders',
      () async {
        final inboxA = await store.createTask(title: 'inbox a');
        final inboxB = await store.createTask(title: 'inbox b');
        final todayA = await store.createTask(
          title: 'today a',
          when: const TaskWhen.date(today),
        );
        final todayB = await store.createTask(
          title: 'today b',
          when: const TaskWhen.date(today),
        );
        await store.reorderTask(inboxB, after: null);
        await store.reorderToday(todayB, after: null);

        final inbox = view(const ListSection(TaskList.inbox));
        expect(inbox.sections, hasLength(1));
        expect(inbox.sections.single.tasks.map((t) => t.id), [inboxB, inboxA]);
        final todayView = view(const ListSection(TaskList.today));
        expect(todayView.sections, hasLength(1));
        expect(todayView.sections.single.tasks.map((t) => t.id), [
          todayB,
          todayA,
        ]);
      },
    );

    test('Upcoming groups by future start first, otherwise deadline', () async {
      final deadlineOnly = await store.createTask(
        title: 'deadline only',
        deadline: const CalendarDate(2026, 8, 26),
      );
      final startWins = await store.createTask(
        title: 'start wins',
        when: const TaskWhen.date(CalendarDate(2026, 8, 25)),
        deadline: const CalendarDate(2026, 8, 27),
      );
      final upcoming = view(const ListSection(TaskList.upcoming));
      expect(upcoming.sections.map((s) => s.day), [
        const CalendarDate(2026, 8, 25),
        const CalendarDate(2026, 8, 26),
      ]);
      expect(upcoming.sections[0].tasks.single.id, startWins);
      expect(upcoming.sections[1].tasks.single.id, deadlineOnly);
    });

    test(
      'Anytime and area/project views expose the full live hierarchy',
      () async {
        final area = await store.createArea(title: 'Home');
        final project = await store.createProject(title: 'Garden', area: area);
        final emptyProject = await store.createProject(
          title: 'Kitchen',
          area: area,
        );
        final headingB = await store.createHeading(
          project: project,
          title: 'Z last title',
        );
        final headingA = await store.createHeading(
          project: project,
          title: 'A first title',
        );
        final direct = await store.createTask(title: 'direct', area: area);
        final unheaded = await store.createTask(
          title: 'unheaded',
          project: project,
        );
        final underB = await store.createTask(
          title: 'under b',
          project: project,
          heading: headingB,
        );
        final underA = await store.createTask(
          title: 'under a',
          project: project,
          heading: headingA,
        );

        final anytime = view(const ListSection(TaskList.anytime));
        expect(anytime.sections.map((s) => s.kind), [
          TaskViewSectionKind.loose,
          TaskViewSectionKind.area,
          TaskViewSectionKind.project,
          TaskViewSectionKind.heading,
          TaskViewSectionKind.heading,
          TaskViewSectionKind.project,
        ]);
        expect(anytime.sections[1].tasks.single.id, direct);
        expect(anytime.sections[2].tasks.single.id, unheaded);
        expect(anytime.sections[3].heading, headingB);
        expect(anytime.sections[3].tasks.single.id, underB);
        expect(anytime.sections[4].heading, headingA);
        expect(anytime.sections[4].tasks.single.id, underA);
        expect(anytime.sections[5].project, emptyProject);
        expect(anytime.sections[5].tasks, isEmpty);

        final areaView = view(AreaSection(area));
        expect(areaView.sections.map((s) => s.kind), [
          TaskViewSectionKind.area,
          TaskViewSectionKind.project,
          TaskViewSectionKind.heading,
          TaskViewSectionKind.heading,
          TaskViewSectionKind.project,
        ]);
        final projectView = view(ProjectSection(project));
        expect(projectView.sections.map((s) => s.kind), [
          TaskViewSectionKind.project,
          TaskViewSectionKind.heading,
          TaskViewSectionKind.heading,
        ]);

        await store.deleteHeading(headingB);
        await store.deleteProject(emptyProject);
        expect(view(ProjectSection(project)).sections.map((s) => s.heading), [
          null,
          headingA,
        ]);
        expect(view(ProjectSection(emptyProject)).sections, isEmpty);
      },
    );

    test(
      'filed Today tasks overlap Anytime without losing hierarchy',
      () async {
        final project = await store.createProject(title: 'P');
        final id = await store.createTask(
          title: 'both',
          project: project,
          when: const TaskWhen.date(today),
        );
        expect(view(const ListSection(TaskList.today)).tasks.map((t) => t.id), [
          id,
        ]);
        expect(
          view(const ListSection(TaskList.anytime)).tasks.map((t) => t.id),
          [id],
        );
      },
    );

    test(
      'Logbook groups local finish days newest-first, including cancelled',
      () async {
        final old = await store.createTask(title: 'old');
        final newer = await store.createTask(title: 'newer');
        final cancelled = await store.createTask(title: 'cancelled');
        await store.completeTask(old, at: DateTime(2026, 8, 23, 23, 59, 59));
        await store.completeTask(newer, at: DateTime(2026, 8, 24));
        await store.cancelTask(cancelled, at: DateTime(2026, 8, 24, 0, 0, 1));
        final logbook = view(const ListSection(TaskList.logbook));
        expect(logbook.sections.map((s) => s.day), [
          const CalendarDate(2026, 8, 24),
          const CalendarDate(2026, 8, 23),
        ]);
        expect(logbook.sections.first.tasks.map((t) => t.id), [
          cancelled,
          newer,
        ]);
        expect(logbook.sections.last.tasks.single.id, old);
      },
    );
  });
}
