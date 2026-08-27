import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/commands.dart';
import 'package:sai_app/find/quick_find.dart';
import 'package:sai_app/workspace/task_list_pane.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

Future<void> chord(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
  await tester.pump();
}

/// A letter, as a keyboard types it: the simulator's default character is
/// the key's upper-case label, so the real one is passed along.
Future<void> type(WidgetTester tester, String letter) async {
  final key = LogicalKeyboardKey.findKeyByKeyId(letter.codeUnitAt(0))!;
  await tester.sendKeyEvent(key, character: letter);
  await tester.pump();
  await tester.pump();
}

Finder get dialog => find.byType(QuickFindDialog);

String fieldText(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(quickFindFieldKey)).controller!.text;

List<String> rows(WidgetTester tester) => [
  for (final row in tester.widgetList<Semantics>(
    find.descendant(
      of: dialog,
      matching: find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.button == true,
      ),
    ),
  ))
    row.properties.label!,
];

void main() {
  final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

  group('Quick Find (#76)', () {
    testWidgets('typing with nothing focused opens it on that letter', (
      tester,
    ) async {
      await pumpApp(tester);
      await type(tester, 'w');
      expect(dialog, findsOneWidget);
      expect(fieldText(tester), 'w');
      final editable = tester.widget<EditableText>(
        find.descendant(of: dialog, matching: find.byType(EditableText)),
      );
      expect(editable.focusNode.hasFocus, isTrue);
      // A second letter lands in the field, not in a second dialog.
      await tester.enterText(find.byKey(quickFindFieldKey), 'wo');
      await tester.pump();
      expect(dialog, findsOneWidget);
    }, variant: macOS);

    testWidgets('typing into a field is typing, not a summons', (tester) async {
      final container = await pumpApp(tester);
      await chord(tester, LogicalKeyboardKey.keyN);
      expect(container.read(captureFocusProvider).hasFocus, isTrue);
      await type(tester, 'w');
      expect(dialog, findsNothing);
      // Keys with no text on them never summon it either.
      container.read(captureFocusProvider).unfocus();
      await tester.pump();
      expect(container.read(captureFocusProvider).hasFocus, isFalse);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'workspace');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(dialog, findsNothing);
    }, variant: macOS);

    testWidgets('⌘K opens it empty, on the lists', (tester) async {
      await pumpApp(tester);
      await chord(tester, LogicalKeyboardKey.keyK);
      expect(dialog, findsOneWidget);
      expect(fieldText(tester), '');
      expect(rows(tester), [
        'Inbox',
        'Today',
        'Upcoming',
        'Anytime',
        'Someday',
        'Logbook',
        'Trash',
      ]);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(dialog, findsNothing);
      // Focus is back on the chrome: typing summons it again.
      await type(tester, 'q');
      expect(dialog, findsOneWidget);
    }, variant: macOS);

    testWidgets('results follow the field, ↓ and ⏎ open a project', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      late ProjectId garden;
      await tester.runAsync(() async {
        garden = await store.createProject(title: 'Garden');
        await store.createProject(title: 'Garage');
        await store.createTask(title: 'Buy gardening gloves');
      });
      await tester.pump();
      await type(tester, 'g');
      // Prefix matches first, then a word that starts with it, then the
      // lists that merely contain a g.
      expect(rows(tester), [
        'Garage',
        'Garden',
        'Buy gardening gloves, Inbox',
        'Logbook',
        'Upcoming',
      ]);
      await tester.enterText(find.byKey(quickFindFieldKey), 'gard');
      await tester.pump();
      expect(rows(tester), ['Garden', 'Buy gardening gloves, Inbox']);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(dialog, findsNothing);
      expect(container.read(selectedSectionProvider), ProjectSection(garden));
      expect(paneTitle(tester), 'Garden');
    }, variant: macOS);

    testWidgets('a heading opens its project, a tag its own view', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      late ProjectId garden;
      late TagId errand;
      await tester.runAsync(() async {
        garden = await store.createProject(title: 'Garden');
        await store.createHeading(project: garden, title: 'Spring beds');
        errand = await store.createTag(title: 'errand');
        await store.createTask(title: 'Buy seeds', tags: [errand]);
      });
      await tester.pump();
      await type(tester, 's');
      await tester.enterText(find.byKey(quickFindFieldKey), 'spring');
      await tester.pump();
      expect(rows(tester), ['Spring beds, Garden']);
      await tester.tap(find.byKey(quickFindResultKey(0)));
      await tester.pump();
      expect(container.read(selectedSectionProvider), ProjectSection(garden));
      await chord(tester, LogicalKeyboardKey.keyK);
      await tester.enterText(find.byKey(quickFindFieldKey), 'errand');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(container.read(selectedSectionProvider), TagSection(errand));
      expect(paneTitle(tester), 'errand');
      expect(rowTitles(tester), ['Buy seeds']);
    }, variant: macOS);

    testWidgets('a task opens where it lives, selected', (tester) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      late TaskId seeds;
      await tester.runAsync(() async {
        final garden = await store.createProject(title: 'Garden');
        seeds = await store.createTask(title: 'Buy seeds', project: garden);
      });
      await tester.pump();
      await type(tester, 'b');
      await tester.enterText(find.byKey(quickFindFieldKey), 'buy se');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(paneTitle(tester), 'Garden');
      expect(container.read(selectedTaskProvider), seeds);
      expect(find.byKey(captureFieldKey), findsOneWidget);
    }, variant: macOS);

    testWidgets('nothing matching says so; Esc leaves without a trace', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      await type(tester, 'z');
      await tester.enterText(find.byKey(quickFindFieldKey), 'zzz');
      await tester.pump();
      expect(find.text('Nothing matches.'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(dialog, findsOneWidget, reason: 'nothing to open');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(dialog, findsNothing);
      expect(
        container.read(selectedSectionProvider),
        const ListSection(TaskList.today),
      );
    }, variant: macOS);
  });
}
