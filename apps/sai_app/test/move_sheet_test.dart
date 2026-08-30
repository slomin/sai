import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/inspector/task_inspector.dart';
import 'package:sai_app/widgets/sai_dialog.dart';
import 'package:sai_app/workspace/move_sheet.dart';
import 'package:sai_app/workspace/placement.dart';
import 'package:sai_app/workspace/task_commands.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

void main() {
  const inbox = ListSection(TaskList.inbox);
  final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

  TaskStore storeOf(ProviderContainer c) =>
      c.read(tasksProvider.notifier).store;

  Map<String, Object?> lastPayload(ProviderContainer c) =>
      (jsonDecode(archiveLines(c.read(archiveRootProvider)).last)
              as Map<String, Object?>)['payload']
          as Map<String, Object?>;

  /// Two areas, a project in each with a heading, and one Inbox task,
  /// selected.
  Future<
    ({
      TaskId task,
      AreaId home,
      AreaId work,
      ProjectId kitchen,
      ProjectId report,
      HeadingId demolition,
      HeadingId figures,
    })
  >
  seed(WidgetTester tester, ProviderContainer container) async {
    final store = storeOf(container);
    final ids = await tester.runAsync(() async {
      final home = await store.createArea(title: 'Home');
      final work = await store.createArea(title: 'Work');
      final kitchen = await store.createProject(title: 'Kitchen', area: home);
      final report = await store.createProject(title: 'Report', area: work);
      final demolition = await store.createHeading(
        project: kitchen,
        title: 'Demolition',
      );
      final figures = await store.createHeading(
        project: report,
        title: 'Figures',
      );
      return (
        home: home,
        work: work,
        kitchen: kitchen,
        report: report,
        demolition: demolition,
        figures: figures,
      );
    });
    await selectSection(tester, container, inbox);
    await capture(tester, container, 'Draft the summary');
    if (container.read(chatVisibleProvider)) {
      container.read(chatVisibleProvider.notifier).toggle();
      await tester.pump();
    }
    final task = store.projection.tasks.keys.single;
    await tester.tap(row(task));
    await tester.pump();
    return (
      task: task,
      home: ids!.home,
      work: ids.work,
      kitchen: ids.kitchen,
      report: ids.report,
      demolition: ids.demolition,
      figures: ids.figures,
    );
  }

  /// A dialog fades in and out; until it has, its subtree carries no
  /// semantics, or it is still on screen.
  Future<void> faded(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> chord(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(key);
    await tester.sendKeyUpEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await faded(tester);
  }

  group('placementOptions', () {
    test('walks the sidebar order with every live heading; archived and '
        'deleted containers are not offered', () async {
      final tmp = Directory.systemTemp.createTempSync('sai_move_sheet');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final store = await TaskStore.open(
        await Archive.open(tmp),
        source: 'sai/app',
      );
      final home = await store.createArea(title: 'Home');
      final kitchen = await store.createProject(title: 'Kitchen', area: home);
      final shelved = await store.createProject(title: 'Old', area: home);
      final solo = await store.createProject(title: 'Solo');
      final demolition = await store.createHeading(
        project: kitchen,
        title: 'Demolition',
      );
      await store.createHeading(project: kitchen, title: 'Fit-out');
      final gone = await store.createHeading(project: solo, title: 'Gone');
      await store.createHeading(project: solo, title: 'Kept');
      await store.archiveProject(shelved);
      await store.deleteHeading(gone);
      final options = placementOptions(store.projection);
      expect(options.map((o) => o.menuLabel), [
        'Inbox — unfiled',
        'Home',
        '    — Kitchen',
        '        · Demolition',
        '        · Fit-out',
        'Solo',
        '    · Kept',
      ]);
      expect(options[3].placement, (
        project: kitchen,
        area: null,
        heading: demolition,
      ));
      expect(options[1].placement, (project: null, area: home, heading: null));
      store.dispose();
    });
  });

  group('the Move / Schedule sheet (#98)', () {
    testWidgets('⇧⌘M, the Task menu and the inspector open the same sheet '
        'on the selected task; Esc writes nothing', (tester) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      final store = storeOf(container);
      final count = store.projection.eventCount;

      await chord(tester, LogicalKeyboardKey.keyM);
      expect(find.byKey(moveSheetKey), findsOneWidget);
      expect(find.text('Draft the summary'), findsWidgets);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      await faded(tester);
      expect(find.byKey(moveSheetKey), findsNothing);

      menuItem(menuDelegate.menus, ['Task', 'Move / Schedule…']).onSelected!();
      await faded(tester);
      expect(find.byKey(moveSheetKey), findsOneWidget);
      await tester.tap(find.text('Cancel').last);
      await tester.pump();
      await tester.pump();
      await faded(tester);
      expect(find.byKey(moveSheetKey), findsNothing);

      await tester.tap(find.byKey(inspectorMoveKey));
      await faded(tester);
      expect(find.byKey(moveSheetKey), findsOneWidget);
      // The current state is marked: no plan, the Inbox.
      expect(
        tester
            .getSemantics(find.byKey(moveOptionKey('none')))
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      expect(
        tester
            .getSemantics(
              find.byKey(
                moveOptionKey((project: null, area: null, heading: null)),
              ),
            )
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      expect(store.projection.eventCount, count);
      expect(container.read(selectedTaskProvider), ids.task);
    }, variant: macOS);

    testWidgets('a schedule writes one edit of when alone; a place one move '
        '— independently, the deadline untouched', (tester) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      final store = storeOf(container);
      final today = container.read(todayProvider);
      const deadline = CalendarDate(2026, 9, 1);
      await settleEvents(
        tester,
        container,
        () => store.editTask(ids.task, deadline: const Patch(deadline)),
      );

      await chord(tester, LogicalKeyboardKey.keyM);
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(moveOptionKey('today'))),
      );
      await faded(tester);
      expect(find.byKey(moveSheetKey), findsNothing);
      var task = store.projection.task(ids.task)!;
      expect(task.when, TaskWhen.date(today));
      expect(task.deadline, deadline);
      expect(task.project, isNull);
      expect(lastPayload(container).keys, containsAll(['task', 'when']));
      expect(lastPayload(container).containsKey('deadline'), isFalse);

      await chord(tester, LogicalKeyboardKey.keyM);
      await settleEvents(
        tester,
        container,
        () => tester.tap(
          find.byKey(
            moveOptionKey((
              project: ids.report,
              area: null,
              heading: ids.figures,
            )),
          ),
        ),
      );
      await faded(tester);
      expect(find.byKey(moveSheetKey), findsNothing);
      task = store.projection.task(ids.task)!;
      expect(task.project, ids.report);
      expect(task.heading, ids.figures);
      expect(task.when, TaskWhen.date(today));
      expect(task.deadline, deadline);
      expect(
        archiveLines(container.read(archiveRootProvider)).last,
        contains('"task.move"'),
      );

      // The other project's heading is offered too, and the mark follows.
      await chord(tester, LogicalKeyboardKey.keyM);
      expect(
        tester
            .getSemantics(
              find.byKey(
                moveOptionKey((
                  project: ids.report,
                  area: null,
                  heading: ids.figures,
                )),
              ),
            )
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      await settleEvents(
        tester,
        container,
        () => tester.tap(
          find.byKey(
            moveOptionKey((
              project: ids.kitchen,
              area: null,
              heading: ids.demolition,
            )),
          ),
        ),
      );
      task = store.projection.task(ids.task)!;
      expect(task.project, ids.kitchen);
      expect(task.heading, ids.demolition);

      await chord(tester, LogicalKeyboardKey.keyM);
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(moveOptionKey('someday'))),
      );
      task = store.projection.task(ids.task)!;
      expect(task.when, TaskWhen.someday);
      expect(task.project, ids.kitchen);
      expect(task.heading, ids.demolition);
    }, variant: macOS);

    testWidgets('the marked place writes nothing and closes — a move without '
        'an anchor would send the task to the end of its group', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      final store = storeOf(container);
      // Two more Inbox tasks, so the task is not last already.
      await capture(tester, container, 'Second');
      await capture(tester, container, 'Third');
      final order = store.projection.structuralOrder;
      expect(order.first, ids.task);
      container.read(selectedTaskProvider.notifier).select(ids.task);
      await tester.pump();
      final count = store.projection.eventCount;
      await chord(tester, LogicalKeyboardKey.keyM);
      await tester.tap(
        find.byKey(moveOptionKey((project: null, area: null, heading: null))),
      );
      await faded(tester);
      expect(find.byKey(moveSheetKey), findsNothing);
      expect(store.projection.eventCount, count);
      expect(store.projection.structuralOrder, order);
    }, variant: macOS);

    testWidgets('a refused destination keeps the sheet up with the reason '
        'and writes nothing', (tester) async {
      // A fresh projection never offers a destination the store would
      // refuse; the refusal is what the store answers when the log has
      // moved on under the sheet, so it is played here by the command.
      final container = await pumpApp(
        tester,
        overrides: [taskCommandsProvider.overrideWith(_RefusingCommands.new)],
      );
      final ids = await seed(tester, container);
      final store = storeOf(container);
      await chord(tester, LogicalKeyboardKey.keyM);
      final count = store.projection.eventCount;
      await tester.tap(
        find.byKey(
          moveOptionKey((project: ids.report, area: null, heading: null)),
        ),
      );
      await settleUntil(
        tester,
        () => find.byKey(dialogErrorKey).evaluate().isNotEmpty,
        () => 'no failure line',
      );
      expect(find.byKey(moveSheetKey), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(dialogErrorKey)).data,
        'project Report is archived',
      );
      expect(store.projection.eventCount, count);
      expect(store.projection.task(ids.task)!.project, isNull);
      // A schedule pick clears the line and goes through.
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(moveOptionKey('someday'))),
      );
      await faded(tester);
      expect(find.byKey(moveSheetKey), findsNothing);
      expect(store.projection.task(ids.task)!.when, TaskWhen.someday);
    }, variant: macOS);

    testWidgets('nothing opens for a task in the Trash or without a '
        'selection', (tester) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      final store = storeOf(container);
      await settleEvents(tester, container, () => store.deleteTask(ids.task));
      await selectSection(tester, container, const TrashSection());
      await tester.tap(row(ids.task));
      await tester.pump();
      expect(find.byKey(inspectorMoveKey), findsNothing);
      await chord(tester, LogicalKeyboardKey.keyM);
      await faded(tester);
      expect(find.byKey(moveSheetKey), findsNothing);
      container.read(selectedTaskProvider.notifier).clear();
      await tester.pump();
      await chord(tester, LogicalKeyboardKey.keyM);
      await faded(tester);
      expect(find.byKey(moveSheetKey), findsNothing);
      expect(
        menuItem(menuDelegate.menus, ['Task', 'Move / Schedule…']).onSelected,
        isNull,
      );
    }, variant: macOS);
  });
}

/// Refuses every place as a stale archive would, and takes schedules.
class _RefusingCommands extends TaskCommands {
  _RefusingCommands(super.ref);

  @override
  Future<String?> tryMove(
    TaskId task, {
    ProjectId? project,
    AreaId? area,
    HeadingId? heading,
  }) async => 'project Report is archived';
}
