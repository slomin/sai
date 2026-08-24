import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

void main() {
  testWidgets('an empty archive shows the greeting and an idle field', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.text('sai 2.0.0-dev — nothing here yet'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
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
    expect(find.text('Inbox (1)'), findsOneWidget);
    expect(find.text('Buy oat milk'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('an @today capture surfaces under Today', (tester) async {
    final container = await pumpApp(tester);
    await capture(tester, container, 'Call mom @today');
    expect(find.text('Today (1)'), findsOneWidget);
    expect(find.text('Inbox (0)'), findsOneWidget);
    expect(find.text('Call mom @today'), findsOneWidget);
  });

  testWidgets('a deadline token renders on the row', (tester) async {
    final container = await pumpApp(tester);
    await capture(tester, container, 'Pay rent !2026-09-01');
    expect(find.text('Pay rent !2026-09-01'), findsOneWidget);
  });

  testWidgets('a blank line captures nothing', (tester) async {
    final container = await pumpApp(tester);
    await capture(tester, container, '   ');
    expect(find.text('sai 2.0.0-dev — nothing here yet'), findsOneWidget);
    expect(archiveLines(container.read(archiveRootProvider)), isEmpty);
  });

  testWidgets('the Undo button reverses the last capture', (tester) async {
    final container = await pumpApp(tester);
    await capture(tester, container, 'Buy oat milk');
    final undo = find.widgetWithText(TextButton, 'Undo');
    expect(tester.widget<TextButton>(undo).onPressed, isNotNull);

    await settleUndo(tester, container, () => tester.tap(undo), depth: 0);
    expect(find.text('sai 2.0.0-dev — nothing here yet'), findsOneWidget);
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

  testWidgets('an unsettled store shows the opening note', (tester) async {
    await pumpApp(
      tester,
      settled: false,
      overrides: [tasksProvider.overrideWith(_StuckTasks.new)],
    );
    expect(find.text('opening the archive…'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
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
