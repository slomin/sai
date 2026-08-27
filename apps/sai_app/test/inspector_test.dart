import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/inspector/checklist_editor.dart';
import 'package:sai_app/inspector/commit_field.dart';
import 'package:sai_app/inspector/tags_editor.dart';
import 'package:sai_app/inspector/task_inspector.dart';
import 'package:sai_app/organise/tags_dialog.dart';
import 'package:sai_app/widgets/sai_dialog.dart';
import 'package:sai_app/workspace/task_commands.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

void main() {
  const inbox = ListSection(TaskList.inbox);
  const today = ListSection(TaskList.today);
  const trash = TrashSection();

  Future<void> chord(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(key);
    await tester.sendKeyUpEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  }

  TaskStore storeOf(ProviderContainer c) =>
      c.read(tasksProvider.notifier).store;

  /// Captures one task into the Inbox, selects its row, and returns its id.
  Future<TaskId> open(
    WidgetTester tester,
    ProviderContainer container, {
    String title = 'Draft the Q3 summary',
  }) async {
    await selectSection(tester, container, inbox);
    await capture(tester, container, title);
    // Tuck the band away: the inspector's lower rows need the height.
    if (container.read(chatVisibleProvider)) {
      container.read(chatVisibleProvider.notifier).toggle();
      await tester.pump();
    }
    final id = storeOf(container).projection.tasks.keys.single;
    await tester.tap(row(id));
    await tester.pump();
    expect(find.byKey(inspectorKey), findsOneWidget);
    return id;
  }

  String titleField(WidgetTester tester) => tester
      .widget<TextField>(
        find.descendant(
          of: find.byKey(inspectorTitleKey),
          matching: find.byType(TextField),
        ),
      )
      .controller!
      .text;

  Finder inField(Key key) =>
      find.descendant(of: find.byKey(key), matching: find.byType(TextField));

  group('opening and closing', () {
    testWidgets('a selected row opens the inspector on that task; ✕ closes', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      expect(find.byKey(inspectorKey), findsNothing);
      final id = await open(tester, container);
      expect(titleField(tester), 'Draft the Q3 summary');
      expect(find.text('No plan'), findsOneWidget);
      expect(find.text('None'), findsOneWidget);
      expect(find.text('Inbox — unfiled'), findsOneWidget);
      expect(find.text('Complete'), findsOneWidget);
      expect(find.text('HASHED · ${shortId(id)}'), findsOneWidget);
      await tester.tap(find.byKey(inspectorCloseKey));
      await tester.pump();
      expect(container.read(selectedTaskProvider), isNull);
      expect(find.byKey(inspectorKey), findsNothing);
    });

    testWidgets('⌘I opens it on the first row and closes it again', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      await selectSection(tester, container, inbox);
      await capture(tester, container, 'a');
      await capture(tester, container, 'b');
      final first = storeOf(container).projection.structuralOrder.first;
      await chord(tester, LogicalKeyboardKey.keyI);
      await tester.pump();
      expect(container.read(selectedTaskProvider), first);
      expect(find.byKey(inspectorKey), findsOneWidget);
      await chord(tester, LogicalKeyboardKey.keyI);
      await tester.pump();
      expect(find.byKey(inspectorKey), findsNothing);
      expect(
        menuItem(menuDelegate.menus, ['View', 'Show Inspector']),
        isNotNull,
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a narrow column keeps the selection but hides the pane', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final id = await open(tester, container);
      tester.view.physicalSize = const Size(860, 700);
      await tester.pump();
      expect(container.read(selectedTaskProvider), id);
      expect(find.byKey(inspectorKey), findsNothing);
      tester.view.physicalSize = const Size(1200, 800);
      await tester.pump();
      expect(find.byKey(inspectorKey), findsOneWidget);
    });

    testWidgets('it stays open when an edit moves the task out of the list; '
        'it closes when the task is deleted', (tester) async {
      final container = await pumpApp(tester);
      final id = await open(tester, container);
      await tester.tap(find.text('No plan'));
      await tester.pump();
      await settleEvents(tester, container, () => tapMenuItem(tester, 'Today'));
      expect(
        storeOf(container).projection.tasks[id]!.when,
        isA<TaskWhenDate>(),
      );
      // Inbox no longer shows it; the inspector still does.
      expect(rowTitles(tester), isEmpty);
      expect(container.read(selectedTaskProvider), id);
      expect(find.byKey(inspectorKey), findsOneWidget);

      await tester.tap(find.byKey(inspectorDeleteKey));
      await tester.pump();
      expect(find.text('Delete “Draft the Q3 summary”?'), findsOneWidget);
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(dialogPrimaryKey)),
      );
      await tester.pump();
      expect(container.read(selectedTaskProvider), isNull);
      expect(find.byKey(inspectorKey), findsNothing);
      expect(sidebarCount(tester, trash), 1);
    });

    testWidgets('the Keep button leaves the task alone', (tester) async {
      final container = await pumpApp(tester);
      final id = await open(tester, container);
      await tester.tap(find.byKey(inspectorDeleteKey));
      await tester.pump();
      await tester.tap(find.text('Keep'));
      await tester.pump();
      expect(storeOf(container).projection.tasks[id]!.deletedAt, isNull);
      expect(container.read(selectedTaskProvider), id);
    });
  });

  group('editing', () {
    testWidgets('the title commits on Enter as one task.edit; undo restores', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final id = await open(tester, container);
      await tester.enterText(inField(inspectorTitleKey), 'Draft the Q3 report');
      await settleEvents(
        tester,
        container,
        () => tester.testTextInput.receiveAction(TextInputAction.done),
      );
      final lines = archiveLines(container.read(archiveRootProvider));
      expect(lines.last, contains('"task.edit"'));
      expect(lines.last, contains('"title":"Draft the Q3 report"'));
      expect(
        storeOf(container).projection.tasks[id]!.title,
        'Draft the Q3 report',
      );
      expect(rowTitles(tester), ['Draft the Q3 report']);
      expect(storeOf(container).undoDepth, 2);
      await settleUndo(
        tester,
        container,
        () => chord(tester, LogicalKeyboardKey.keyZ),
        depth: 1,
      );
      expect(titleField(tester), 'Draft the Q3 summary');
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('notes commit when the field is left; Escape reverts a draft', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final id = await open(tester, container);
      await tester.enterText(inField(inspectorNotesKey), 'Numbers from Ops.');
      // Leaving the field (focus moves to the title) commits.
      await settleEvents(
        tester,
        container,
        () => tester.tap(inField(inspectorTitleKey)),
      );
      expect(
        storeOf(container).projection.tasks[id]!.notes,
        'Numbers from Ops.',
      );

      await tester.enterText(inField(inspectorTitleKey), 'typo');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(titleField(tester), 'Draft the Q3 summary');
      expect(
        storeOf(container).projection.tasks[id]!.title,
        'Draft the Q3 summary',
      );
      expect(storeOf(container).projection.eventCount, 2);
    });

    testWidgets('a refused edit keeps the draft and names the reason', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final id = await open(tester, container);
      await tester.enterText(inField(inspectorTitleKey), '');
      await tester.runAsync(
        () => tester.testTextInput.receiveAction(TextInputAction.done),
      );
      await tester.pump();
      expect(find.text('edit failed: title must not be empty'), findsOneWidget);
      expect(titleField(tester), '');
      expect(
        storeOf(container).projection.tasks[id]!.title,
        'Draft the Q3 summary',
      );
    });

    testWidgets('an outside change re-seeds an unfocused field', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final id = await open(tester, container);
      await settleEvents(
        tester,
        container,
        () => storeOf(container).editTask(id, title: const Patch('Renamed')),
      );
      expect(titleField(tester), 'Renamed');
    });

    testWidgets('deadline and where write the right events', (tester) async {
      final container = await pumpApp(tester);
      final id = await open(tester, container);
      final store = storeOf(container);
      final home = await tester.runAsync(() => store.createArea(title: 'Home'));
      final kitchen = await tester.runAsync(
        () => store.createProject(title: 'Kitchen', area: home),
      );
      await tester.runAsync(
        () => store.createHeading(project: kitchen!, title: 'Demolition'),
      );
      await tester.pump();

      await tester.tap(find.text('None'));
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => tapMenuItem(tester, 'Tomorrow'),
      );
      final day = container.read(todayProvider).addDays(1);
      expect(store.projection.tasks[id]!.deadline, day);

      await tester.tap(find.text('Inbox — unfiled'));
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => tapMenuItem(tester, '    — Kitchen'),
      );
      expect(store.projection.tasks[id]!.project, kitchen);
      expect(find.text('Kitchen'), findsWidgets);
      // In a project now: its headings are offered.
      await tester.tap(find.text('Kitchen').first);
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => tapMenuItem(tester, '        · Demolition'),
      );
      final task = store.projection.tasks[id]!;
      expect(task.heading, isNotNull);
      expect(task.project, kitchen);
      final lines = archiveLines(container.read(archiveRootProvider));
      expect(lines.last, contains('"task.move"'));
    });

    testWidgets(
      'tags: an existing one completes, a new name creates, ✕ removes',
      (tester) async {
        final container = await pumpApp(tester);
        final id = await open(tester, container);
        final store = storeOf(container);
        final errand = await tester.runAsync(
          () => store.createTag(title: 'errand'),
        );
        await tester.pump();

        await tester.enterText(find.byKey(tagFieldKey), 'err');
        await tester.pump();
        await settleEvents(
          tester,
          container,
          () => tester.tap(find.text('errand')),
        );
        expect(store.projection.tasks[id]!.tags, [errand]);
        expect(find.text('ERRAND'), findsWidgets);

        await tester.enterText(find.byKey(tagFieldKey), 'work');
        await settleEvents(
          tester,
          container,
          () => tester.testTextInput.receiveAction(TextInputAction.done),
          count: 2,
        );
        final work = store.projection.tags.values
            .firstWhere((t) => t.title == 'work')
            .id;
        expect(store.projection.tasks[id]!.tags, [errand, work]);

        await settleEvents(
          tester,
          container,
          () => tester.tap(find.byKey(removeTagKey(errand!))),
        );
        expect(store.projection.tasks[id]!.tags, [work]);
        expect(
          tester
              .getSemantics(
                find.descendant(
                  of: find.byKey(removeTagKey(work)),
                  matching: find.byType(InkWell),
                ),
              )
              .label,
          'Remove tag work',
        );
      },
    );

    testWidgets('a partial name attaches the suggestion, never a second tag; '
        'a deleted assigned tag does not block the next one', (tester) async {
      final container = await pumpApp(tester);
      final id = await open(tester, container);
      final store = storeOf(container);
      final errand = await tester.runAsync(
        () => store.createTag(title: 'errand'),
      );
      await tester.pump();
      await tester.enterText(find.byKey(tagFieldKey), 'err');
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => tester.testTextInput.receiveAction(TextInputAction.done),
      );
      // One event: the edit attaching errand. No "err" tag was created.
      expect(store.projection.tasks[id]!.tags, [errand]);
      expect(store.projection.tags.values.map((t) => t.title), ['errand']);

      await settleEvents(tester, container, () => store.deleteTag(errand!));
      expect(find.text('ERRAND'), findsNothing);
      await tester.enterText(find.byKey(tagFieldKey), 'work');
      await settleEvents(
        tester,
        container,
        () => tester.testTextInput.receiveAction(TextInputAction.done),
        count: 2,
      );
      final work = store.projection.tags.values
          .firstWhere((t) => t.title == 'work')
          .id;
      expect(store.projection.tasks[id]!.tags, [work]);
      expect(find.text('WORK'), findsWidgets);
    });

    testWidgets('the checklist adds, toggles, renames and removes items', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final id = await open(tester, container);
      final store = storeOf(container);
      await tester.enterText(find.byKey(checklistAddKey), 'Gather numbers');
      await settleEvents(
        tester,
        container,
        () => tester.testTextInput.receiveAction(TextInputAction.done),
      );
      await tester.enterText(find.byKey(checklistAddKey), 'Write it');
      await settleEvents(
        tester,
        container,
        () => tester.testTextInput.receiveAction(TextInputAction.done),
      );
      expect(store.projection.tasks[id]!.checklist.map((i) => i.title), [
        'Gather numbers',
        'Write it',
      ]);
      expect(find.text('0 OF 2'), findsOneWidget);

      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(checklistBoxKey(0))),
      );
      expect(
        store.projection.tasks[id]!.checklist.first.completedAt,
        isNotNull,
      );
      expect(find.text('1 OF 2'), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(checklistBoxKey(0))).label,
        'Reopen Gather numbers',
      );

      final second = find.descendant(
        of: find.byType(CommitField).at(3),
        matching: find.byType(TextField),
      );
      await tester.enterText(second, 'Write two pages');
      await settleEvents(
        tester,
        container,
        () => tester.testTextInput.receiveAction(TextInputAction.done),
      );
      expect(
        store.projection.tasks[id]!.checklist.last.title,
        'Write two pages',
      );

      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(checklistRemoveKey(0))),
      );
      expect(store.projection.tasks[id]!.checklist.map((i) => i.title), [
        'Write two pages',
      ]);
      final lines = archiveLines(container.read(archiveRootProvider));
      expect(lines.last, contains('"task.checklist"'));
    });

    testWidgets('the footer completes, reopens, cancels; the Trash restores', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final id = await open(tester, container);
      final store = storeOf(container);
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(inspectorPrimaryKey)),
      );
      expect(store.projection.tasks[id]!.status, TaskStatus.completed);
      expect(find.text('Reopen'), findsOneWidget);
      expect(find.byKey(inspectorCancelKey), findsNothing);
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(inspectorPrimaryKey)),
      );
      expect(store.projection.tasks[id]!.status, TaskStatus.open);
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(inspectorCancelKey)),
      );
      expect(store.projection.tasks[id]!.status, TaskStatus.cancelled);

      await settleEvents(tester, container, () => store.deleteTask(id));
      expect(container.read(selectedTaskProvider), isNull);
      await selectSection(tester, container, trash);
      await tester.tap(row(id));
      await tester.pump();
      expect(find.text('TASK · IN THE TRASH'), findsOneWidget);
      expect(find.text('Restore'), findsOneWidget);
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(inspectorPrimaryKey)),
      );
      expect(store.projection.tasks[id]!.deletedAt, isNull);
      // Restored out of the Trash: the row is gone, the inspector stays.
      expect(rowTitles(tester), isEmpty);
      expect(container.read(selectedTaskProvider), id);
    });

    testWidgets('⌘⏎ completes the selected task; ⌘⌫ asks before deleting', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final id = await open(tester, container);
      final store = storeOf(container);
      // Focus a row, not a field: the chord is the app's.
      await tester.tap(row(id));
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => chord(tester, LogicalKeyboardKey.enter),
      );
      expect(store.projection.tasks[id]!.status, TaskStatus.completed);
      await chord(tester, LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(find.text('Delete “Draft the Q3 summary”?'), findsOneWidget);
      await tester.tap(find.text('Keep'));
      await tester.pump();
      expect(store.projection.tasks[id]!.deletedAt, isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('⌘⏎ and Cancel leave a task in the Trash alone', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final id = await open(tester, container);
      final store = storeOf(container);
      await settleEvents(tester, container, () => store.deleteTask(id));
      await selectSection(tester, container, trash);
      await tester.tap(row(id));
      await tester.pump();
      final count = store.projection.eventCount;
      await chord(tester, LogicalKeyboardKey.enter);
      menuItem(menuDelegate.menus, ['Task', 'Cancel']).onSelected!();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(store.projection.eventCount, count);
      expect(store.projection.tasks[id]!.status, TaskStatus.open);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('Manage… opens the tags dialog', (tester) async {
      final container = await pumpApp(tester);
      await open(tester, container);
      await tester.tap(find.text('Manage…'));
      await tester.pump();
      expect(find.byType(TagsDialog), findsOneWidget);
      expect(find.text('No tags yet.'), findsOneWidget);
    });

    testWidgets('describeFailure unwraps the store\'s reason', (tester) async {
      expect(
        describeFailure(
          TaskProjectionError(
            eventId: BlobRef.sha256OfBytes(const [1]),
            reason: 'project x is archived',
          ),
        ),
        'project x is archived',
      );
      expect(
        describeFailure(ArgumentError('title must not be empty')),
        'title must not be empty',
      );
      expect(describeFailure(StateError('gone')), 'gone');
      expect(describeFailure(Exception('odd')), 'Exception: odd');
    });
  });

  group('concurrent change', () {
    testWidgets('a second writer\'s edit shows after reload; the selection '
        'and a focused draft survive', (tester) async {
      final container = await pumpApp(tester);
      final id = await open(tester, container);
      final root = container.read(archiveRootProvider);
      await tester.runAsync(() async {
        final archive = await Archive.open(root);
        final other = await TaskStore.open(archive, source: 'sai/tui');
        await other.editTask(id, notes: const Patch('from the terminal'));
        other.dispose();
        await archive.close();
      });
      await tester.enterText(inField(inspectorTitleKey), 'my draft');
      await tester.runAsync(
        () => container.read(tasksProvider.notifier).reload(),
      );
      await tester.pump();
      expect(container.read(selectedTaskProvider), id);
      expect(find.text('from the terminal'), findsWidgets);
      expect(titleField(tester), 'my draft', reason: 'the focused draft wins');
    });
  });

  group('accessibility', () {
    testWidgets('every control is labelled and the pane survives 1.3× text', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final id = await open(tester, container);
      expect(
        tester
            .getSemantics(
              find.descendant(
                of: find.byKey(inspectorCloseKey),
                matching: find.byType(InkWell),
              ),
            )
            .label,
        'Close inspector',
      );
      expect(tester.getSemantics(find.text('No plan')).label, 'When, No plan');
      expect(
        tester.getSemantics(find.text('Inbox — unfiled')).label,
        'Where, Inbox — unfiled',
      );
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final size in const [Size(1200, 800), Size(1440, 900)]) {
        tester.view.physicalSize = size;
        await tester.pump();
        expect(find.byKey(inspectorKey), findsOneWidget, reason: '$size');
      }
      expect(container.read(selectedTaskProvider), id);
      // No RenderFlex overflow is the assertion: flutter_test fails on one.
    });
  });

  group('goldens', () {
    testWidgets('the inspector as the reference shows it', (tester) async {
      // A pinned clock: the header shows the task's id, which hashes the
      // event line — timestamp included.
      var micros = DateTime.utc(2026, 8, 26, 9, 2).microsecondsSinceEpoch;
      final container = await pumpApp(
        tester,
        clock: () {
          micros += 1000000;
          return DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
        },
      );
      final store = storeOf(container);
      await tester.runAsync(() async {
        final work = await store.createArea(title: 'Work');
        final q3 = await store.createProject(title: 'Q3 report', area: work);
        final id = await store.createTask(
          title: 'Draft the Q3 summary',
          notes: 'Numbers from Ops are still missing. Keep it to two pages.',
          when: TaskWhen.date(container.read(todayProvider)),
          deadline: container.read(todayProvider).addDays(3),
          project: q3,
          checklist: [
            ChecklistItem(
              title: 'Gather numbers',
              completedAt: DateTime.utc(2026, 8, 26, 9),
            ),
            const ChecklistItem(title: 'Write two pages'),
            const ChecklistItem(title: 'Send to Dana'),
          ],
        );
        await store.createTask(
          title: 'Book the dentist',
          when: TaskWhen.date(container.read(todayProvider)),
        );
        container.read(selectedTaskProvider.notifier).select(id);
      });
      await selectSection(tester, container, today);
      await tester.pump();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/inspector.png'),
      );
    });
  });
}
