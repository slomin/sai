import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/sai_app.dart';
import 'package:sai_core/sai_core.dart';

/// Pumps [SaiApp] over a per-test temp archive root. Client tests must
/// never touch the real archive under Application Support, so every
/// test goes through here (or overrides [tasksProvider] outright).
///
/// With [settled], the task store is opened (real file I/O, hence
/// [WidgetTester.runAsync]) before the first frame, so the tree renders
/// data immediately — no polling.
Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  List<Override> overrides = const [],
  bool settled = true,
}) async {
  final root = Directory.systemTemp.createTempSync('sai_app_test');
  addTearDown(() => root.deleteSync(recursive: true));
  final container = ProviderContainer.test(
    overrides: [
      archiveRootProvider.overrideWithValue(root),
      eventSourceProvider.overrideWithValue(EventSources.app),
      ...overrides,
    ],
  );
  if (settled) {
    await tester.runAsync(() => container.read(tasksProvider.future));
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const SaiApp()),
  );
  await tester.pump();
  return container;
}

/// Types [line] into the capture field and submits it, waiting (under
/// real async) until the store has committed the resulting event — or
/// confirmed it committed nothing, for a blank line.
Future<void> capture(
  WidgetTester tester,
  ProviderContainer container,
  String line,
) async {
  final store = container.read(tasksProvider.notifier).store;
  final expected =
      store.projection.eventCount +
      (parseQuickCapture(line, today: container.read(todayProvider)) == null
          ? 0
          : 1);
  await tester.enterText(find.byType(TextField), line);
  await tester.runAsync(() async {
    await tester.testTextInput.receiveAction(TextInputAction.done);
    while (store.projection.eventCount < expected) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  });
  await tester.pump();
}

/// Runs [act] (a tap or key chord that triggers an undo) under real
/// async and waits until the store's undo stack has shrunk to [depth].
Future<void> settleUndo(
  WidgetTester tester,
  ProviderContainer container,
  Future<void> Function() act, {
  required int depth,
}) async {
  final store = container.read(tasksProvider.notifier).store;
  await tester.runAsync(() async {
    await act();
    while (store.undoDepth > depth) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  });
  await tester.pump();
}

/// Every event line under [root], oldest first.
List<String> archiveLines(Directory root) {
  final dir = Directory('${root.path}/events');
  if (!dir.existsSync()) return const [];
  final lines = <String>[];
  final files = dir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    lines.addAll(
      file.readAsStringSync().split('\n').where((l) => l.isNotEmpty),
    );
  }
  return lines;
}
