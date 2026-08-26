import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_app/assistant/assistant_band.dart';
import 'package:sai_app/theme/sai_tokens.dart';
import 'package:sai_app/widgets/chip.dart';
import 'package:sai_app/widgets/empty_state.dart';
import 'package:sai_app/widgets/glyph_button.dart';
import 'package:sai_app/workspace/task_list.dart';
import 'package:sai_app/workspace/task_row.dart';
import 'package:sai_app/workspace/task_row_chips.dart';
import 'package:sai_app/workspace/task_section_header.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

void main() {
  const inbox = ListSection(TaskList.inbox);
  const today = ListSection(TaskList.today);
  const upcoming = ListSection(TaskList.upcoming);
  const logbook = ListSection(TaskList.logbook);

  group('taskRowChips', () {
    final base = DateTime.utc(2026, 8, 24, 10);
    const day = CalendarDate(2026, 8, 26);
    Task task({
      CalendarDate? deadline,
      TaskWhen when = TaskWhen.none,
      List<ChecklistItem> checklist = const [],
      DateTime? completedAt,
      DateTime? cancelledAt,
    }) => Task(
      id: BlobRef.sha256OfBytes([1]),
      title: 't',
      deadline: deadline,
      when: when,
      checklist: checklist,
      createdAt: base,
      modifiedAt: base,
      completedAt: completedAt,
      cancelledAt: cancelledAt,
    );

    test('a due deadline is the one red chip; a later one is tonal', () {
      expect(
        taskRowChips(
          task(deadline: day),
          today: day,
          section: today,
        ),
        [const ChipSpec('DUE Wed 26 Aug', ChipTone.due)],
      );
      expect(
        taskRowChips(
          task(deadline: const CalendarDate(2026, 8, 28)),
          today: day,
          section: today,
        ),
        [const ChipSpec('Fri 28 Aug', ChipTone.tonal)],
      );
    });

    test('SOMEDAY surfaces only in Today; the container only where useful', () {
      final someday = task(when: TaskWhen.someday, deadline: day);
      expect(
        taskRowChips(someday, today: day, section: today, container: 'Home'),
        [
          const ChipSpec('DUE Wed 26 Aug', ChipTone.due),
          const ChipSpec('SOMEDAY', ChipTone.flat),
          const ChipSpec('Home', ChipTone.flat),
        ],
      );
      expect(
        taskRowChips(
          task(),
          today: day,
          section: AreaSection(BlobRef.sha256OfBytes([2])),
          container: 'Home',
          tags: ['errand'],
        ),
        [const ChipSpec('errand', ChipTone.flat)],
      );
    });

    test('checklist progress and how a task ended', () {
      expect(
        taskRowChips(
          task(
            checklist: [
              ChecklistItem(title: 'a', completedAt: base),
              const ChecklistItem(title: 'b'),
            ],
            completedAt: DateTime(2026, 8, 26, 18, 22),
          ),
          today: day,
          section: logbook,
        ),
        [
          const ChipSpec('1/2', ChipTone.tonal),
          const ChipSpec('18:22', ChipTone.flat),
        ],
      );
      expect(
        taskRowChips(
          task(cancelledAt: base),
          today: day,
          section: logbook,
        ),
        [const ChipSpec('CANCELLED', ChipTone.flat)],
      );
    });
  });

  group('the standard lists', () {
    testWidgets('Upcoming groups by day, soonest first, with the day named', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      final day = container.read(todayProvider);
      await tester.runAsync(() async {
        await store.createTask(
          title: 'Later',
          when: TaskWhen.date(day.addDays(3)),
        );
        await store.createTask(
          title: 'Soon',
          when: TaskWhen.date(day.addDays(1)),
        );
        await store.createTask(title: 'Due', deadline: day.addDays(1));
      });
      await selectSection(tester, container, upcoming);
      expect(paneTitle(tester), 'Upcoming');
      expect(find.byType(TaskSectionHeader), findsNWidgets(2));
      expect(find.textContaining('· TOMORROW'), findsOneWidget);
      expect(rowTitles(tester), ['Soon', 'Due', 'Later']);
      expect(
        tester.getTopLeft(find.byType(TaskSectionHeader).first).dy,
        lessThan(tester.getTopLeft(row(store.projection.tasks.keys.first)).dy),
      );
    });

    testWidgets('the Logbook groups by the day finished, newest day first', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      final now = DateTime.now();
      await tester.runAsync(() async {
        final old = await store.createTask(title: 'Old');
        final fresh = await store.createTask(title: 'Fresh');
        final dropped = await store.createTask(title: 'Dropped');
        await store.completeTask(
          old,
          at: now.subtract(const Duration(days: 2)),
        );
        await store.completeTask(
          fresh,
          at: now.subtract(const Duration(minutes: 1)),
        );
        await store.cancelTask(dropped, at: now);
      });
      await selectSection(tester, container, logbook);
      expect(find.byType(TaskSectionHeader), findsNWidgets(2));
      expect(rowTitles(tester), ['Dropped', 'Fresh', 'Old']);
      expect(find.text('CANCELLED'), findsOneWidget);
      // Finished rows strike their titles through.
      final title = tester.widget<Text>(
        find.descendant(
          of: find.byType(TaskRow).first,
          matching: find.text('Dropped'),
        ),
      );
      expect(title.style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('a project shows its loose tasks, then each heading', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      late ProjectId project;
      await tester.runAsync(() async {
        project = await store.createProject(title: 'Kitchen redo');
        final heading = await store.createHeading(
          project: project,
          title: 'Tiles',
        );
        await store.createTask(title: 'Measure', project: project);
        await store.createTask(
          title: 'Order tiles',
          project: project,
          heading: heading,
        );
      });
      await selectSection(tester, container, ProjectSection(project));
      expect(paneTitle(tester), 'Kitchen redo');
      expect(rowTitles(tester), ['Measure', 'Order tiles']);
      expect(find.text('TILES'), findsOneWidget);
    });

    testWidgets('a task filed in Today shows its project and its tags', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      final day = container.read(todayProvider);
      await tester.runAsync(() async {
        final project = await store.createProject(title: 'Q3 report');
        final tag = await store.createTag(title: 'work');
        await store.createTask(
          title: 'Draft the Q3 summary',
          notes: 'Numbers from Ops are still missing.\nSecond line.',
          project: project,
          tags: [tag],
          when: TaskWhen.date(day),
          deadline: day.addDays(2),
        );
      });
      await tester.pump();
      expect(find.text('Q3 REPORT'), findsOneWidget);
      expect(find.text('WORK'), findsOneWidget);
      expect(find.text('Numbers from Ops are still missing.'), findsOneWidget);
      expect(find.text('1 TASK · 1 WITH DEADLINES'), findsOneWidget);
    });

    testWidgets('each list has its own empty state', (tester) async {
      final container = await pumpApp(tester);
      final copies = <SidebarSection, String>{
        inbox: 'Inbox is clear.',
        today: 'Nothing planned for today.',
        upcoming: 'Nothing scheduled.',
        const ListSection(TaskList.anytime): 'Nothing filed for anytime.',
        const ListSection(TaskList.someday): 'Nothing on the long list.',
        logbook: 'Nothing finished yet.',
        const TrashSection(): 'Trash is empty.',
      };
      for (final entry in copies.entries) {
        await selectSection(tester, container, entry.key);
        expect(find.byType(EmptyState), findsOneWidget);
        expect(find.text(entry.value), findsOneWidget);
      }
    });
  });

  group('the rows', () {
    testWidgets('clicking a row selects it; the selection leaves with it', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      await selectSection(tester, container, inbox);
      await capture(tester, container, 'Buy oat milk');
      final id = container.read(tasksProvider).value!.tasks.keys.single;
      await tester.tap(row(id));
      await tester.pump();
      expect(container.read(selectedTaskProvider), id);
      final decoration =
          tester
                  .widget<Container>(
                    find
                        .descendant(
                          of: row(id),
                          matching: find.byType(Container),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      expect(decoration.color, SaiColors.surf);
      expect(tester.getSemantics(row(id)).label, contains('selected'));

      await selectSection(tester, container, today);
      expect(container.read(selectedTaskProvider), isNull);
    });

    testWidgets('the check completes the task and the row leaves', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      await selectSection(tester, container, inbox);
      await capture(tester, container, 'Buy oat milk');
      await capture(tester, container, 'Water the plants');
      final ids = container.read(tasksProvider).value!.structuralOrder;
      await tester.tap(row(ids.first));
      await tester.pump();
      await settleEvents(tester, container, () => tester.tap(check(ids.first)));
      final lines = archiveLines(container.read(archiveRootProvider));
      expect(lines.last, contains('"task.complete"'));
      // Reduced motion: the confirmation and the collapse take one frame.
      await tester.pump();
      await tester.pump();
      expect(rowTitles(tester), ['Water the plants']);
      // The task still exists, so the selection (and the inspector) stay
      // on it (#74); only a deletion or a section change clears it.
      expect(container.read(selectedTaskProvider), ids.first);
      expect(sidebarCount(tester, logbook), 1);
    });

    testWidgets('undo brings the row back where it was', (tester) async {
      final container = await pumpApp(tester);
      await selectSection(tester, container, inbox);
      for (final title in ['One', 'Two', 'Three']) {
        await capture(tester, container, title);
      }
      final ids = container.read(tasksProvider).value!.structuralOrder;
      await settleEvents(tester, container, () => tester.tap(check(ids[1])));
      await tester.pump();
      await tester.pump();
      expect(rowTitles(tester), ['One', 'Three']);
      await settleUndo(
        tester,
        container,
        () => tester.tap(find.text('Undo')),
        depth: 3,
      );
      await tester.pump();
      expect(rowTitles(tester), ['One', 'Two', 'Three']);
    });

    testWidgets('the cross cancels the task', (tester) async {
      final container = await pumpApp(tester);
      await selectSection(tester, container, inbox);
      await capture(tester, container, 'Buy oat milk');
      final id = container.read(tasksProvider).value!.tasks.keys.single;
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(cancelButtonKey(id))),
      );
      final lines = archiveLines(container.read(archiveRootProvider));
      expect(lines.last, contains('"task.cancel"'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(TaskRow), findsNothing);
      expect(find.text('Inbox is clear.'), findsOneWidget);
    });

    testWidgets('the check in the Logbook reopens the task', (tester) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      late TaskId id;
      await tester.runAsync(() async {
        id = await store.createTask(title: 'Done thing');
        await store.completeTask(id);
      });
      await selectSection(tester, container, logbook);
      await settleEvents(tester, container, () => tester.tap(check(id)));
      expect(store.projection.task(id)!.status, TaskStatus.open);
      expect(find.byType(TaskRow), findsNothing);
      expect(sidebarCount(tester, inbox), 1);
    });

    testWidgets('a refused completion keeps the row and says why', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      await selectSection(tester, container, inbox);
      await capture(tester, container, 'Buy oat milk');
      final id = container.read(tasksProvider).value!.tasks.keys.single;
      container.read(tasksProvider.notifier).store.dispose();
      await tester.runAsync(() async {
        await tester.tap(check(id));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('complete failed:'), findsOneWidget);
      expect(row(id), findsOneWidget);
    });

    testWidgets('a new row grows in; a finished row confirms, then collapses', (
      tester,
    ) async {
      final container = await pumpApp(tester, reduceMotion: false);
      await selectSection(tester, container, inbox);
      await capture(tester, container, 'One');
      await capture(tester, container, 'Two');
      final ids = container.read(tasksProvider).value!.structuralOrder;
      // The second row entered after the first frame: it is still growing.
      final growing = tester.getSize(row(ids[1])).height;
      await tester.pump(SaiDurations.enter);
      await tester.pump();
      expect(tester.getSize(row(ids[1])).height, greaterThan(growing));
      final full = tester.getSize(row(ids[1])).height;

      await settleEvents(tester, container, () => tester.tap(check(ids[0])));
      // The store has moved on, the ghost holds its place and confirms.
      expect(rowTitles(tester), ['One', 'Two']);
      expect(find.text('COMPLETED'), findsOneWidget);
      // A controller started between frames takes its start time from
      // the next frame that moves the clock: a frame to start the hold,
      // the hold, a frame to start the collapse, then half of it.
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(SaiDurations.hold);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(SaiDurations.collapse ~/ 2);
      expect(tester.getSize(find.byType(TaskRow).first).height, lessThan(full));
      await tester.pump(SaiDurations.collapse);
      await tester.pump();
      expect(rowTitles(tester), ['Two']);
      expect(find.text('COMPLETED'), findsNothing);
    });
  });

  group('ghosts', () {
    testWidgets('a day that empties keeps its ghost under that day', (
      tester,
    ) async {
      final container = await pumpApp(tester, reduceMotion: false);
      final store = container.read(tasksProvider.notifier).store;
      final day = container.read(todayProvider);
      late TaskId soon;
      await tester.runAsync(() async {
        soon = await store.createTask(
          title: 'Soon',
          when: TaskWhen.date(day.addDays(1)),
        );
        await store.createTask(
          title: 'Later',
          when: TaskWhen.date(day.addDays(3)),
        );
      });
      await selectSection(tester, container, upcoming);
      await tester.pump(SaiDurations.enter);
      await settleEvents(tester, container, () => tester.tap(check(soon)));
      // The view lost tomorrow; the ghost still confirms under it, above
      // the later day, not under the later day's header.
      expect(find.byType(TaskSectionHeader), findsNWidgets(2));
      expect(find.textContaining('· TOMORROW'), findsOneWidget);
      expect(find.text('COMPLETED'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('COMPLETED')).dy,
        lessThan(tester.getTopLeft(find.byType(TaskSectionHeader).last).dy),
      );
      await pumpUntil(tester, () => find.text('COMPLETED').evaluate().isEmpty);
      await tester.pump();
      expect(find.byType(TaskSectionHeader), findsOneWidget);
      expect(rowTitles(tester), ['Later']);
    });

    testWidgets('the last row confirms before the empty state shows', (
      tester,
    ) async {
      final container = await pumpApp(tester, reduceMotion: false);
      await selectSection(tester, container, inbox);
      await capture(tester, container, 'Only one');
      await tester.pump(SaiDurations.enter);
      final id = container.read(tasksProvider).value!.tasks.keys.single;
      await settleEvents(tester, container, () => tester.tap(check(id)));
      expect(find.text('COMPLETED'), findsOneWidget);
      expect(find.byType(EmptyState), findsNothing);
      await pumpUntil(
        tester,
        () => find.byType(EmptyState).evaluate().isNotEmpty,
      );
      expect(find.byType(TaskRow), findsNothing);
      expect(find.text('Inbox is clear.'), findsOneWidget);
    });

    testWidgets('a ghost stays in the view it left', (tester) async {
      final container = await pumpApp(tester, reduceMotion: false);
      final store = container.read(tasksProvider.notifier).store;
      final day = container.read(todayProvider);
      late TaskId id;
      await tester.runAsync(() async {
        id = await store.createTask(title: 'Gone');
        await store.createTask(title: 'Stays', when: TaskWhen.date(day));
      });
      await selectSection(tester, container, inbox);
      await tester.pump(SaiDurations.enter);
      await settleEvents(tester, container, () => tester.tap(check(id)));
      expect(find.text('COMPLETED'), findsOneWidget);
      await selectSection(tester, container, today);
      expect(find.text('COMPLETED'), findsNothing);
      expect(rowTitles(tester), ['Stays']);
      await tester.pump(SaiDurations.hold);
      await tester.pump(SaiDurations.collapse);
    });
  });

  group('scrolling', () {
    testWidgets('each list opens at its top', (tester) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      final day = container.read(todayProvider);
      await tester.runAsync(() async {
        for (var i = 0; i < 30; i++) {
          await store.createTask(title: 'T$i', when: TaskWhen.date(day));
          await store.createTask(title: 'I$i');
        }
      });
      await tester.pump();
      Finder list() => find.descendant(
        of: find.byType(TaskListBody),
        matching: find.byType(Scrollable),
      );
      await tester.drag(list(), const Offset(0, -600));
      await tester.pump();
      expect(
        tester.state<ScrollableState>(list()).position.pixels,
        greaterThan(0),
      );
      await selectSection(tester, container, inbox);
      expect(tester.state<ScrollableState>(list()).position.pixels, 0);
      expect(find.text('I0'), findsOneWidget);
    });
  });

  group('reordering', () {
    testWidgets('dragging a row by its check reorders Today, and it persists', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      final day = container.read(todayProvider);
      await tester.runAsync(() async {
        for (final title in ['A', 'B', 'C']) {
          await store.createTask(title: title, when: TaskWhen.date(day));
        }
      });
      await tester.pump();
      expect(rowTitles(tester), ['A', 'B', 'C']);
      final ids = store.projection.todayOrder;
      await settleEvents(tester, container, () async {
        // Well past the two rows below: the drop lands after the last one.
        final step = tester.getSize(row(ids[0])).height;
        await tester.drag(check(ids[0]), Offset(0, 4 * step));
        await tester.pump(const Duration(milliseconds: 300));
      });
      expect(
        archiveLines(container.read(archiveRootProvider)).last,
        contains('"task.reorder"'),
      );
      await tester.pump();
      expect(rowTitles(tester), ['B', 'C', 'A']);
      await tester.runAsync(store.reload);
      await tester.pump();
      expect(rowTitles(tester), ['B', 'C', 'A']);
    });

    testWidgets('the Inbox reorders its structural order', (tester) async {
      final container = await pumpApp(tester);
      await selectSection(tester, container, inbox);
      for (final title in ['A', 'B', 'C']) {
        await capture(tester, container, title);
      }
      final ids = container.read(tasksProvider).value!.structuralOrder;
      await settleEvents(tester, container, () async {
        final step = tester.getSize(row(ids[2])).height;
        await tester.drag(check(ids[2]), Offset(0, -4 * step));
        await tester.pump(const Duration(milliseconds: 300));
      });
      expect(
        archiveLines(container.read(archiveRootProvider)).last,
        contains('"task.move"'),
      );
      await tester.pump();
      expect(rowTitles(tester), ['C', 'A', 'B']);
    });

    testWidgets('Upcoming and the Logbook keep their order', (tester) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      final day = container.read(todayProvider);
      await tester.runAsync(() async {
        await store.createTask(title: 'A', when: TaskWhen.date(day.addDays(1)));
        await store.createTask(title: 'B', when: TaskWhen.date(day.addDays(1)));
      });
      await selectSection(tester, container, upcoming);
      final view = container.read(taskViewProvider(upcoming)).value!;
      expect(reorderable(view, view.sections.single), isFalse);
      expect(find.byType(SliverReorderableList), findsNothing);
    });
  });

  group('accessibility', () {
    Future<ProviderContainer> populated(WidgetTester tester) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      final day = container.read(todayProvider);
      await tester.runAsync(() async {
        final work = await store.createArea(title: 'Work');
        final q3 = await store.createProject(
          title: 'Quarterly report for the board',
          area: work,
        );
        final tag = await store.createTag(title: 'correspondence');
        await store.createTask(
          title:
              'A rather long task title that keeps going well past the '
              'width a row would like to give it',
          notes: 'And a note under it, also on the long side of things.',
          when: TaskWhen.date(day),
          deadline: day,
          project: q3,
          tags: [tag],
          checklist: const [ChecklistItem(title: 'x')],
        );
        await store.createTask(title: 'Short', when: TaskWhen.date(day));
      });
      await tester.pump();
      return container;
    }

    for (final size in const [Size(900, 600), Size(1440, 900)]) {
      testWidgets('the layout survives 1.3× text at $size', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final container = await populated(tester);
        tester.view.physicalSize = size;
        await tester.pump();
        // No RenderFlex overflow is the assertion: flutter_test fails on one.
        expect(find.byType(TaskRow), findsNWidgets(2));
        for (final section in [
          const ListSection(TaskList.inbox),
          const ListSection(TaskList.logbook),
          const ListSection(TaskList.upcoming),
        ]) {
          await selectSection(tester, container, section);
        }
        container.read(chatVisibleProvider.notifier).toggle();
        await tester.pump();
        container.read(chatVisibleProvider.notifier).toggle();
        await tester.pump();
      });
    }

    testWidgets('every control carries a name', (tester) async {
      final container = await populated(tester);
      final ids = container.read(tasksProvider).value!.todayOrder;
      expect(tester.getSemantics(check(ids[1])).label, 'Complete Short');
      expect(tester.getSemantics(row(ids[1])).label, startsWith('Short'));
      expect(
        tester.widget<GlyphButton>(find.byKey(cancelButtonKey(ids[1]))).label,
        'Cancel Short',
      );
      expect(
        tester.getSemantics(find.byKey(assistantHeaderKey)).label,
        'Tuck the assistant away',
      );
      expect(tester.getSemantics(sidebarRow(today)).label, 'Today, 2');
      expect(find.byType(TaskSectionHeader), findsNothing);
    });
  });

  group('goldens', () {
    testWidgets('Today, populated as the reference shows it', (tester) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      final day = container.read(todayProvider);
      await tester.runAsync(() async {
        final work = await store.createArea(title: 'Work');
        final q3 = await store.createProject(title: 'Q3 report', area: work);
        final home = await store.createArea(title: 'Home');
        final errand = await store.createTag(title: 'errand');
        final email = await store.createTag(title: 'email');
        await store.createTask(
          title: 'Book the dentist',
          when: TaskWhen.date(day),
          deadline: day,
          tags: [errand],
        );
        await store.createTask(
          title: 'Reply to Dana about the venue',
          when: TaskWhen.date(day),
          tags: [email],
        );
        await store.createTask(
          title: 'Draft the Q3 summary',
          notes: 'Numbers from Ops are still missing. Keep it to two pages.',
          when: TaskWhen.date(day),
          deadline: day.addDays(2),
          project: q3,
          checklist: const [
            ChecklistItem(title: 'Numbers'),
            ChecklistItem(title: 'Draft'),
            ChecklistItem(title: 'Review'),
          ],
        );
        await store.createTask(
          title: 'Water the plants',
          when: TaskWhen.date(day),
          area: home,
        );
      });
      await tester.pump();
      container.read(chatVisibleProvider.notifier).toggle();
      await tester.pump();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/today.png'),
      );
    });

    for (final (section, name) in [
      (today, 'today'),
      (inbox, 'inbox'),
      (logbook, 'logbook'),
    ]) {
      testWidgets('the empty $name list', (tester) async {
        final container = await pumpApp(tester);
        await selectSection(tester, container, section);
        await expectLater(
          find.byType(EmptyState),
          matchesGoldenFile('goldens/empty-$name.png'),
        );
      });
    }
  });
}
