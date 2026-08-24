import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/main_pane.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

void main() {
  const inbox = ListSection(TaskList.inbox);

  TextField captureField(WidgetTester tester) =>
      tester.widget<TextField>(find.byKey(captureFieldKey));

  testWidgets('an empty archive shows the greeting and an idle field', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.text('sai 2.0.0-dev — nothing here yet'), findsOneWidget);
    expect(find.byKey(captureFieldKey), findsOneWidget);
    final undo = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Undo'),
    );
    expect(undo.onPressed, isNull);
  });

  testWidgets('a captured line lands in the Inbox and clears the field', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    await capture(tester, container, 'Buy oat milk');
    // Counted in the sidebar straight away…
    expect(find.text('Inbox (1)'), findsOneWidget);
    expect(captureField(tester).controller!.text, isEmpty);
    // …and listed once the Inbox is the section on show.
    expect(find.text('Buy oat milk'), findsNothing);
    await selectSection(tester, container, inbox);
    expect(find.text('Buy oat milk'), findsOneWidget);
  });

  testWidgets('an @today capture surfaces under Today', (tester) async {
    final container = await pumpApp(tester);
    await capture(tester, container, 'Call mom @today');
    expect(find.text('Today (1)'), findsOneWidget);
    expect(find.text('Inbox (0)'), findsOneWidget);
    expect(find.text('Upcoming (0)'), findsOneWidget);
    expect(find.text('Someday (0)'), findsOneWidget);
    // Today is the section the shell opens on.
    expect(find.text('Call mom @today'), findsOneWidget);
  });

  testWidgets('a deadline token counts in Inbox and in Upcoming', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    await capture(tester, container, 'Pay rent !2026-09-01');
    // The view union: a due-later Inbox task also surfaces in Upcoming.
    expect(find.text('Inbox (1)'), findsOneWidget);
    expect(find.text('Upcoming (1)'), findsOneWidget);
    await selectSection(
      tester,
      container,
      const ListSection(TaskList.upcoming),
    );
    expect(find.text('Pay rent !2026-09-01'), findsOneWidget);
  });

  testWidgets('a blank line captures nothing', (tester) async {
    final container = await pumpApp(tester);
    await capture(tester, container, '   ');
    expect(find.text('sai 2.0.0-dev — nothing here yet'), findsOneWidget);
    expect(find.text('Inbox (0)'), findsOneWidget);
    expect(archiveLines(container.read(archiveRootProvider)), isEmpty);
  });

  testWidgets('the Undo button reverses the last capture', (tester) async {
    final container = await pumpApp(tester);
    await capture(tester, container, 'Buy oat milk');
    await selectSection(tester, container, inbox);
    final undo = find.widgetWithText(TextButton, 'Undo');
    expect(tester.widget<TextButton>(undo).onPressed, isNotNull);

    await settleUndo(tester, container, () => tester.tap(undo), depth: 0);
    expect(find.text('sai 2.0.0-dev — nothing here yet'), findsOneWidget);
    expect(find.text('Trash (1)'), findsOneWidget);
    final projection = container.read(tasksProvider).value!;
    expect(projection.trash().single.title, 'Buy oat milk');
    expect(tester.widget<TextButton>(undo).onPressed, isNull);
  });

  testWidgets('Cmd+Z undoes with the capture field focused', (tester) async {
    final container = await pumpApp(tester);
    await capture(tester, container, 'Buy oat milk');
    await settleUndo(tester, container, () async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    }, depth: 0);
    expect(container.read(tasksProvider).value!.trash(), hasLength(1));
  });

  testWidgets('a capture is an archive event with actor and timestamp', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    await capture(tester, container, 'Buy oat milk');
    final lines = archiveLines(container.read(archiveRootProvider));
    expect(lines, hasLength(1));
    final json = jsonDecode(lines.single) as Map<String, Object?>;
    expect(json['type'], 'task.create');
    expect(json['actor'], 'user');
    expect(json['source'], 'sai/app');
    expect(json['payload'], {'title': 'Buy oat milk'});
    expect(() => parseTs(json['ts']! as String), returnsNormally);
  });

  testWidgets('@tomorrow and @someday captures reach their lists', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    await capture(tester, container, 'Ring dentist @tomorrow');
    await capture(tester, container, 'Learn the violin @someday');
    expect(find.text('Upcoming (1)'), findsOneWidget);
    expect(find.text('Someday (1)'), findsOneWidget);
    await selectSection(
      tester,
      container,
      const ListSection(TaskList.upcoming),
    );
    expect(find.text('Ring dentist @tomorrow'), findsOneWidget);
    await selectSection(tester, container, const ListSection(TaskList.someday));
    expect(find.text('Learn the violin @someday'), findsOneWidget);
  });

  testWidgets('a failed capture keeps the line and says so', (tester) async {
    final container = await pumpApp(tester);
    container.read(tasksProvider.notifier).store.dispose();
    await tester.enterText(find.byKey(captureFieldKey), 'Buy oat milk');
    await tester.runAsync(() async {
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.textContaining('capture failed:'), findsOneWidget);
    expect(captureField(tester).controller!.text, 'Buy oat milk');
  });

  testWidgets('a failed undo says so and keeps the button', (tester) async {
    final container = await pumpApp(tester);
    await capture(tester, container, 'Buy oat milk');
    container.read(tasksProvider.notifier).store.dispose();
    await tester.tap(find.widgetWithText(TextButton, 'Undo'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(find.textContaining('undo failed:'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Undo'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('an unsettled store shows the opening note', (tester) async {
    await pumpApp(
      tester,
      settled: false,
      overrides: [tasksProvider.overrideWith(_StuckTasks.new)],
    );
    expect(find.text('opening the archive…'), findsOneWidget);
    expect(find.byKey(captureFieldKey), findsNothing);
  });

  testWidgets('a failed open shows the error', (tester) async {
    await pumpApp(
      tester,
      settled: false,
      overrides: [tasksProvider.overrideWith(_FailingTasks.new)],
    );
    await tester.pump();
    expect(find.textContaining('archive error:'), findsOneWidget);
  });
}

class _StuckTasks extends TasksNotifier {
  @override
  Future<TaskProjection> build() => Completer<TaskProjection>().future;
}

class _FailingTasks extends TasksNotifier {
  @override
  Future<TaskProjection> build() async {
    throw StateError('no archive today');
  }
}
