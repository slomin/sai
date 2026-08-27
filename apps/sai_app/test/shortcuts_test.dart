import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/assistant/assistant_band.dart';
import 'package:sai_app/commands.dart';
import 'package:sai_app/providers_dialog.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

Future<void> chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool alt = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
  await tester.pump();
}

void main() {
  final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

  group('the standard shortcuts (#76)', () {
    testWidgets('nothing is focused at launch; ⌘N brings the capture field', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      expect(container.read(captureFocusProvider).hasFocus, isFalse);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'workspace');
      await chord(tester, LogicalKeyboardKey.keyN);
      expect(container.read(captureFocusProvider).hasFocus, isTrue);
    }, variant: macOS);

    testWidgets('⌘1–⌘6 switch the lists and ⌘7 opens the Trash', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final digits = [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4,
        LogicalKeyboardKey.digit5,
        LogicalKeyboardKey.digit6,
      ];
      for (final (i, list) in TaskList.values.indexed) {
        await chord(tester, digits[i]);
        expect(paneTitle(tester), listTitle(list));
        expect(container.read(selectedSectionProvider), ListSection(list));
      }
      await chord(tester, LogicalKeyboardKey.digit7);
      expect(paneTitle(tester), trashTitle);
      expect(container.read(selectedSectionProvider), const TrashSection());
    }, variant: macOS);

    testWidgets('⌥⌘⏎ cancels the selected task', (tester) async {
      final container = await pumpApp(tester);
      await capture(tester, container, 'Draft it');
      final store = container.read(tasksProvider.notifier).store;
      final id = store.projection.tasks.keys.single;
      await selectSection(tester, container, const ListSection(TaskList.inbox));
      await tester.tap(row(id));
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => chord(tester, LogicalKeyboardKey.enter, alt: true),
      );
      expect(store.projection.tasks[id]!.status, TaskStatus.cancelled);
    }, variant: macOS);

    testWidgets('⌘, opens the providers dialog', (tester) async {
      await pumpApp(tester);
      await chord(tester, LogicalKeyboardKey.comma);
      expect(find.byType(ProvidersDialog), findsOneWidget);
    }, variant: macOS);

    testWidgets('a Task command from inside the assistant touches nothing', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      await capture(tester, container, 'Draft it');
      final store = container.read(tasksProvider.notifier).store;
      final id = store.projection.tasks.keys.single;
      await selectSection(tester, container, const ListSection(TaskList.inbox));
      await tester.tap(row(id));
      await tester.pump();
      expect(container.read(selectedTaskProvider), id);
      await tester.tap(find.byKey(chatFieldKey));
      await tester.pump();
      expect(container.read(assistantFocusProvider).hasFocus, isTrue);
      final count = store.projection.eventCount;
      await chord(tester, LogicalKeyboardKey.enter);
      await chord(tester, LogicalKeyboardKey.enter, alt: true);
      await chord(tester, LogicalKeyboardKey.backspace);
      // The menu item is enabled — a task is selected — but says no too.
      menuItem(menuDelegate.menus, ['Task', 'Complete']).onSelected!();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(store.projection.eventCount, count);
      expect(find.text('Delete “Draft it”?'), findsNothing);
      expect(container.read(selectedTaskProvider), id, reason: 'still chosen');
      // Back on the list — a click, as on a Mac: a text field lets go of
      // focus on a pointer tap outside it, not on a touch — the same
      // chord is the task's again.
      await tester.tap(row(id), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(container.read(assistantFocusProvider).hasFocus, isFalse);
      await settleEvents(
        tester,
        container,
        () => chord(tester, LogicalKeyboardKey.enter),
      );
      expect(store.projection.tasks[id]!.status, TaskStatus.completed);
    }, variant: macOS);
  });
}
