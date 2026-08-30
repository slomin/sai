import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_app/assistant/assistant_band.dart';
import 'package:sai_app/commands.dart';
import 'package:sai_app/settings/settings_screen.dart';
import 'package:sai_app/sidebar.dart';
import 'package:sai_app/theme/sai_tokens.dart';
import 'package:sai_app/top_bar.dart';
import 'package:sai_app/widgets/cog_button.dart';
import 'package:sai_app/widgets/check_mark.dart';
import 'package:sai_app/widgets/chip.dart';
import 'package:sai_app/widgets/empty_state.dart';
import 'package:sai_app/widgets/glyph_button.dart';
import 'package:sai_app/widgets/sai_dialog.dart';
import 'package:sai_app/workspace/move_sheet.dart';
import 'package:sai_app/workspace/task_list.dart';
import 'package:sai_app/workspace/task_menu.dart';
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
      final now = container.read(clockProvider)();
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
      final container = await pumpApp(
        tester,
        finishedTasks: FinishedTaskVisibility.immediate,
      );
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
      final container = await pumpApp(
        tester,
        finishedTasks: FinishedTaskVisibility.immediate,
      );
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
      final container = await pumpApp(
        tester,
        finishedTasks: FinishedTaskVisibility.immediate,
      );
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
      final container = await pumpApp(
        tester,
        reduceMotion: false,
        finishedTasks: FinishedTaskVisibility.immediate,
      );
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
      final container = await pumpApp(
        tester,
        reduceMotion: false,
        finishedTasks: FinishedTaskVisibility.immediate,
      );
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
      final container = await pumpApp(
        tester,
        reduceMotion: false,
        finishedTasks: FinishedTaskVisibility.immediate,
      );
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
      final container = await pumpApp(
        tester,
        reduceMotion: false,
        finishedTasks: FinishedTaskVisibility.immediate,
      );
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

  group('finished rows stay until midnight (#97)', () {
    testWidgets('the check greys the row in place; the Logbook has it too', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      await selectSection(tester, container, inbox);
      for (final title in ['One', 'Two', 'Three']) {
        await capture(tester, container, title);
      }
      final ids = container.read(tasksProvider).value!.structuralOrder;
      await tester.tap(row(ids[1]));
      await tester.pump();
      await settleEvents(tester, container, () => tester.tap(check(ids[1])));
      expect(
        archiveLines(container.read(archiveRootProvider)).last,
        contains('"task.complete"'),
      );
      await tester.pump();
      await tester.pump();
      // Still there, at its place, finished — and no ghost's chip.
      expect(rowTitles(tester), ['One', 'Two', 'Three']);
      expect(find.text('COMPLETED'), findsNothing);
      expect(find.byKey(ValueKey('ghost-${ids[1]}')), findsNothing);
      final title = tester.widget<Text>(
        find.descendant(of: row(ids[1]), matching: find.text('Two')),
      );
      expect(title.style!.decoration, TextDecoration.lineThrough);
      expect(title.style!.color, SaiColors.inkFaint);
      expect(tester.getSemantics(row(ids[1])).label, contains('completed'));
      expect(container.read(selectedTaskProvider), ids[1]);
      // Counted nowhere but the Logbook; the pane's meta counts the open.
      expect(sidebarCount(tester, inbox), 2);
      expect(sidebarCount(tester, logbook), 1);
      expect(find.text('2 TASKS'), findsOneWidget);
      // The ✕ is gone from a finished row.
      expect(find.byKey(cancelButtonKey(ids[1])), findsNothing);
      await selectSection(tester, container, logbook);
      expect(rowTitles(tester), ['Two']);
    });

    testWidgets('the cross cancels in place, with the CANCELLED chip', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      await selectSection(tester, container, inbox);
      await capture(tester, container, 'Buy oat milk');
      final id = container.read(tasksProvider).value!.tasks.keys.single;
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(cancelButtonKey(id))),
      );
      await tester.pump();
      await tester.pump();
      expect(rowTitles(tester), ['Buy oat milk']);
      expect(find.text('CANCELLED'), findsOneWidget);
      expect(find.text('Inbox is clear.'), findsNothing);
      expect(tester.getSemantics(row(id)).label, contains('cancelled'));
      expect(sidebarCount(tester, inbox), 0);
    });

    testWidgets('the check on a kept row reopens it where it stands', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      await selectSection(tester, container, inbox);
      for (final title in ['One', 'Two', 'Three']) {
        await capture(tester, container, title);
      }
      final ids = container.read(tasksProvider).value!.structuralOrder;
      await settleEvents(tester, container, () => tester.tap(check(ids[1])));
      await tester.pump();
      expect(tester.getSemantics(check(ids[1])).label, startsWith('Reopen'));
      await settleEvents(tester, container, () => tester.tap(check(ids[1])));
      expect(
        archiveLines(container.read(archiveRootProvider)).last,
        contains('"task.reopen"'),
      );
      await tester.pump();
      expect(rowTitles(tester), ['One', 'Two', 'Three']);
      expect(
        tester.getSemantics(row(ids[1])).label,
        isNot(contains('completed')),
      );
      expect(sidebarCount(tester, inbox), 3);
      expect(sidebarCount(tester, logbook), 0);
    });

    testWidgets('Delete moves a kept row to the Trash', (tester) async {
      final container = await pumpApp(tester);
      await selectSection(tester, container, inbox);
      await capture(tester, container, 'Buy oat milk');
      final id = container.read(tasksProvider).value!.tasks.keys.single;
      await settleEvents(tester, container, () => tester.tap(check(id)));
      await tester.tap(row(id));
      await tester.pump();
      menuItem(menuDelegate.menus, ['Task', 'Delete…']).onSelected!();
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(dialogPrimaryKey)),
      );
      await tester.pump();
      expect(find.byType(TaskRow), findsNothing);
      expect(sidebarCount(tester, const TrashSection()), 1);
      expect(sidebarCount(tester, logbook), 0);
    });

    testWidgets('a row in the Trash offers selection and nothing else', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      late TaskId open, done;
      await tester.runAsync(() async {
        open = await store.createTask(title: 'Gone thing');
        await store.deleteTask(open);
        done = await store.createTask(title: 'Done and gone');
        await store.cancelTask(done);
        await store.deleteTask(done);
      });
      await selectSection(tester, container, const TrashSection());
      expect(rowTitles(tester), ['Done and gone', 'Gone thing']);
      // An open task in the Trash has no box to tick; a finished one keeps
      // its mark as a plain indicator — neither announces an action.
      expect(
        find.descendant(of: row(open), matching: find.byType(CheckMark)),
        findsNothing,
      );
      final mark = tester.widget<CheckMark>(
        find.descendant(of: row(done), matching: find.byType(CheckMark)),
      );
      expect(mark.onTap, isNull);
      expect(mark.cancelled, isTrue);
      for (final id in [open, done]) {
        final label = tester.getSemantics(row(id)).label;
        expect(label, isNot(contains('Complete')), reason: label);
        expect(label, isNot(contains('Reopen')), reason: label);
        expect(find.byKey(cancelButtonKey(id)), findsNothing);
      }
      expect(tester.getSemantics(row(done)).label, contains('cancelled'));
      final count = store.projection.eventCount;
      await tester.tap(row(open));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(store.projection.eventCount, count, reason: 'nothing written');
      expect(container.read(selectedTaskProvider), open, reason: 'selectable');
      expect(find.text('Restore'), findsOneWidget, reason: 'the inspector');
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.text('Restore')),
      );
      expect(store.projection.task(open)!.deletedAt, isNull);
      expect(find.text('1 TASK'), findsOneWidget, reason: 'the Trash counts');
    });

    testWidgets('the Logbook and the Trash count what they hold', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      await tester.runAsync(() async {
        for (final title in ['One', 'Two', 'Three']) {
          final id = await store.createTask(title: title);
          await store.completeTask(id);
        }
      });
      await selectSection(tester, container, logbook);
      expect(rowTitles(tester), hasLength(3));
      expect(find.text('3 TASKS'), findsWidgets, reason: 'meta and day header');
      expect(find.text('0 TASKS'), findsNothing);
      // The same rows kept in the Inbox are shown, not counted: nothing
      // is left to do there, as the sidebar says.
      await selectSection(tester, container, inbox);
      expect(rowTitles(tester), hasLength(3));
      expect(find.text('0 TASKS'), findsOneWidget);
      expect(sidebarCount(tester, inbox), 0);
    });

    testWidgets('a drag past a kept row anchors on the live row above', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      await selectSection(tester, container, inbox);
      for (final title in ['A', 'B', 'C']) {
        await capture(tester, container, title);
      }
      final ids = container.read(tasksProvider).value!.structuralOrder;
      await settleEvents(tester, container, () => tester.tap(check(ids[1])));
      await tester.pump();
      expect(rowTitles(tester), ['A', 'B', 'C']);
      await settleEvents(tester, container, () async {
        final step = tester.getSize(row(ids[0])).height;
        // A over B (finished) and C: it lands last, anchored on C.
        await tester.drag(check(ids[0]), Offset(0, 4 * step));
        await tester.pump(const Duration(milliseconds: 300));
      });
      final line = archiveLines(container.read(archiveRootProvider)).last;
      expect(line, contains('"task.move"'));
      expect(line, contains('"after":"${ids[2]}"'), reason: 'C, not B');
      await tester.pump();
      expect(rowTitles(tester), ['B', 'C', 'A']);
      // And back to the top: nothing live above, so it goes first, and
      // the finished B keeps its place.
      await settleEvents(tester, container, () async {
        final step = tester.getSize(row(ids[0])).height;
        await tester.drag(check(ids[0]), Offset(0, -4 * step));
        await tester.pump(const Duration(milliseconds: 300));
      });
      expect(
        archiveLines(container.read(archiveRootProvider)).last,
        contains('"after":null'),
      );
      await tester.pump();
      expect(rowTitles(tester), ['A', 'B', 'C']);
    });
  });

  group('the row menu and Move up / Move down (#98)', () {
    Future<void> chord(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyUpEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      await tester.pump();
    }

    Future<List<TaskId>> three(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      await selectSection(tester, container, inbox);
      for (final title in ['A', 'B', 'C']) {
        await capture(tester, container, title);
      }
      return container.read(tasksProvider).value!.structuralOrder;
    }

    List<String> menuLabels(WidgetTester tester) => [
      for (final e in find.byType(MenuItemButton).evaluate())
        ((e.widget as MenuItemButton).child as Text).data!,
    ];

    testWidgets('the … button and a secondary click open the menu and '
        'select the row; the Trash has neither', (tester) async {
      final container = await pumpApp(tester);
      final ids = await three(tester, container);
      expect(
        tester
            .getSemantics(
              find.descendant(
                of: find.byKey(taskMenuKey(ids[1])),
                matching: find.byType(InkWell),
              ),
            )
            .label,
        'Options for B',
      );
      await tester.tap(find.byKey(taskMenuKey(ids[1])));
      await tester.pump();
      expect(container.read(selectedTaskProvider), ids[1]);
      expect(menuLabels(tester), [
        'Move / Schedule…',
        'Move up',
        'Move down',
        'Complete',
        'Cancel',
        'Delete…',
      ]);
      await tester.tap(find.byKey(taskMenuKey(ids[1])));
      await tester.pump();
      expect(find.byType(MenuItemButton), findsNothing);

      final gesture = await tester.startGesture(
        tester.getCenter(row(ids[2])),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pump();
      expect(container.read(selectedTaskProvider), ids[2]);
      expect(find.widgetWithText(MenuItemButton, 'Move up'), findsOneWidget);
      await tester.tap(find.widgetWithText(MenuItemButton, 'Move / Schedule…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(moveSheetKey), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // A finished row offers Reopen and no Cancel; the Trash no menu.
      await settleEvents(tester, container, () => tester.tap(check(ids[0])));
      await tester.tap(find.byKey(taskMenuKey(ids[0])));
      await tester.pump();
      expect(menuLabels(tester), ['Move / Schedule…', 'Reopen', 'Delete…']);
      await tester.tap(find.byKey(taskMenuKey(ids[0])));
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => container.read(tasksProvider.notifier).store.deleteTask(ids[0]),
      );
      await selectSection(tester, container, const TrashSection());
      expect(find.byKey(taskMenuKey(ids[0])), findsNothing);
    });

    testWidgets('Move down writes one reorder with the right anchor; the '
        'ends and a kept view write nothing', (tester) async {
      final container = await pumpApp(tester);
      final ids = await three(tester, container);
      final store = container.read(tasksProvider.notifier).store;
      await tester.tap(find.byKey(taskMenuKey(ids[0])));
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => tapMenuItem(tester, 'Move down'),
      );
      var line = archiveLines(container.read(archiveRootProvider)).last;
      expect(line, contains('"task.move"'));
      expect(line, contains('"after":"${ids[1]}"'));
      expect(rowTitles(tester), ['B', 'A', 'C']);
      expect(container.read(selectedTaskProvider), ids[0]);

      // ⌘↓ again, then ⌘↑ twice: the last press is at the top.
      await settleEvents(
        tester,
        container,
        () => chord(tester, LogicalKeyboardKey.arrowDown),
      );
      expect(rowTitles(tester), ['B', 'C', 'A']);
      var count = store.projection.eventCount;
      await chord(tester, LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(store.projection.eventCount, count);
      await settleEvents(
        tester,
        container,
        () => chord(tester, LogicalKeyboardKey.arrowUp),
        count: 1,
      );
      await settleEvents(
        tester,
        container,
        () => chord(tester, LogicalKeyboardKey.arrowUp),
        count: 1,
      );
      line = archiveLines(container.read(archiveRootProvider)).last;
      expect(line, contains('"after":null'));
      expect(rowTitles(tester), ['A', 'B', 'C']);

      // Today has its own order and its own event.
      await settleEvents(
        tester,
        container,
        () => store.editTask(
          ids[1],
          when: Patch(TaskWhen.date(container.read(todayProvider))),
        ),
      );
      await settleEvents(
        tester,
        container,
        () => store.editTask(
          ids[2],
          when: Patch(TaskWhen.date(container.read(todayProvider))),
        ),
      );
      await selectSection(tester, container, today);
      expect(rowTitles(tester), ['B', 'C']);
      container.read(selectedTaskProvider.notifier).select(ids[2]);
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => chord(tester, LogicalKeyboardKey.arrowUp),
      );
      line = archiveLines(container.read(archiveRootProvider)).last;
      expect(line, contains('"task.reorder"'));
      expect(rowTitles(tester), ['C', 'B']);
      expect(store.projection.structuralOrder, ids);

      // Upcoming keeps its order: no items, and the chord is inert.
      await settleEvents(
        tester,
        container,
        () => store.editTask(
          ids[1],
          when: Patch(TaskWhen.date(container.read(todayProvider).addDays(1))),
        ),
      );
      await selectSection(tester, container, upcoming);
      container.read(selectedTaskProvider.notifier).select(ids[1]);
      await tester.pump();
      count = store.projection.eventCount;
      await chord(tester, LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(store.projection.eventCount, count);
      await tester.tap(find.byKey(taskMenuKey(ids[1])));
      await tester.pump();
      expect(find.widgetWithText(MenuItemButton, 'Move up'), findsNothing);
      expect(find.widgetWithText(MenuItemButton, 'Move down'), findsNothing);
      await tester.tap(find.byKey(taskMenuKey(ids[1])));
      await tester.pump();
    });

    testWidgets('a plain arrow still moves the selection', (tester) async {
      final container = await pumpApp(tester);
      final ids = await three(tester, container);
      container.read(captureFocusProvider).unfocus();
      container.read(selectedTaskProvider.notifier).select(ids[0]);
      await tester.pump();
      final count = container.read(tasksProvider).value!.eventCount;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(container.read(selectedTaskProvider), ids[1]);
      expect(container.read(tasksProvider).value!.eventCount, count);
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

    testWidgets('the top bar fits a 640-wide window', (tester) async {
      // Plain text size: the band's header (#99's) overflows at 1.3× here
      // with or without the cog; the bar is what this measures.
      await populated(tester);
      tester.view.physicalSize = const Size(640, 700);
      await tester.pump();
      // No RenderFlex overflow is the assertion; the cog stays on the bar.
      final bar = tester.getRect(find.byType(TopBar));
      final cog = tester.getRect(find.byKey(settingsButtonKey));
      expect(cog.right, lessThanOrEqualTo(bar.right));
      expect(find.byKey(undoButtonKey), findsOneWidget);
    });

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
        startsWith('Tuck the assistant away'),
      );
      expect(tester.getSemantics(sidebarRow(today)).label, 'Today, 2');
      expect(
        tester.widget<CogButton>(find.byKey(settingsButtonKey)).label,
        'Settings',
      );
      expect(find.byType(TaskSectionHeader), findsNothing);
    });
  });

  group('the Settings cog (#96)', () {
    final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

    bool generalSelected(WidgetTester tester) => tester
        .widget<SidebarRow>(find.byKey(settingsNavKey(SettingsSection.general)))
        .selected;

    testWidgets('a click opens General, as ⌘, does; Esc leaves', (
      tester,
    ) async {
      await pumpApp(tester);
      expect(find.byKey(settingsScreenKey), findsNothing);
      await tester.tap(find.byKey(settingsButtonKey));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(settingsScreenKey), findsOneWidget);
      expect(generalSelected(tester), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(settingsScreenKey), findsNothing);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'workspace');
    }, variant: macOS);

    testWidgets('assistive tech activates it through its own node', (
      tester,
    ) async {
      await pumpApp(tester);
      final handle = tester.ensureSemantics();
      await tester.pump();
      final button = find.descendant(
        of: find.byKey(settingsButtonKey),
        matching: find.bySemanticsLabel('Settings'),
      );
      expect(
        tester
            .getSemantics(button)
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue,
      );
      tester.semantics.performAction(
        find.semantics.byLabel('Settings'),
        SemanticsAction.tap,
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(settingsScreenKey), findsOneWidget);
      handle.dispose();
    });

    testWidgets('it is a named button the keyboard reaches', (tester) async {
      await pumpApp(tester);
      expect(
        find.descendant(
          of: find.byKey(settingsButtonKey),
          matching: find.bySemanticsLabel('Settings'),
        ),
        findsOneWidget,
      );
      // Tab from the resting scope walks the chrome; the cog is on it.
      final cog = find.byKey(settingsButtonKey);
      var focused = false;
      for (var i = 0; i < 24 && !focused; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final context = FocusManager.instance.primaryFocus?.context;
        focused =
            context != null &&
            find
                .ancestor(of: find.byWidget(context.widget), matching: cog)
                .evaluate()
                .isNotEmpty;
      }
      expect(focused, isTrue, reason: 'Tab never reached the cog');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(settingsScreenKey), findsOneWidget);
      expect(generalSelected(tester), isTrue);
    }, variant: macOS);
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
