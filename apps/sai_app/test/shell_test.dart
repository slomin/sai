import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_core/sai_core.dart';
import 'package:yaml/yaml.dart';

import 'harness.dart';

void main() {
  testWidgets('the shell reads through the shared provider layer', (
    tester,
  ) async {
    await pumpApp(
      tester,
      overrides: [llmStatusProvider.overrideWithValue('override status')],
    );
    expect(find.text('override status'), findsOneWidget);
  });

  testWidgets('the appearance is light — a dark variant is a later ticket', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await pumpApp(tester);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.light);
    expect(app.darkTheme, isNull);
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.light,
    );
  });

  testWidgets('the board follows a task another process wrote (#118)', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    // Another process on the same log — the terminal client, say.
    await tester.runAsync(() async {
      final other = await Archive.open(container.read(archiveRootProvider));
      final theirs = await TaskStore.open(other, source: EventSources.tui);
      await theirs.createTask(title: 'From the terminal');
      theirs.dispose();
      await other.close();
    });
    await tester.pump();
    expect(find.text('From the terminal'), findsNothing);

    final follower = container.read(archiveFollowerProvider.notifier);
    await tester.runAsync(follower.tick);
    await tester.pump();
    // Today opens; the Inbox count in the sidebar carries the new row.
    expect(find.text('From the terminal'), findsNothing);
    expect(container.read(archiveFollowerProvider).reloads, 1);
    container
        .read(selectedSectionProvider.notifier)
        .select(const ListSection(TaskList.inbox));
    await tester.pump();
    expect(find.text('From the terminal'), findsOneWidget);
  });

  testWidgets('a check that fails is the top bar\'s notice (#118)', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    // A line the reducer refuses in log order: another process created a
    // task in a project this one had deleted by the time the line landed.
    await tester.runAsync(() async {
      final store = container.read(tasksProvider.notifier).store;
      final project = await store.createProject(title: 'P');
      final other = await Archive.open(container.read(archiveRootProvider));
      final stale = await TaskStore.open(other, source: EventSources.tui);
      await store.deleteProject(project);
      await stale.createTask(
        title: 'imported',
        project: project,
        by: const Attribution.system(),
      );
      stale.dispose();
      await other.close();
    });
    final follower = container.read(archiveFollowerProvider.notifier);
    await tester.runAsync(follower.tick);
    await tester.pump();
    expect(find.textContaining('reload failed:'), findsOneWidget);
    final state = container.read(archiveFollowerProvider);
    expect(state.reloads, 0);
    expect(state.failure, contains('TaskProjectionError'));
    expect(find.text('imported'), findsNothing);
  });

  test('pubspec version matches saiVersion (build metadata aside)', () {
    // `flutter test` always runs with the project directory as CWD.
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    expect((pubspec['version'] as String).split('+').first, saiVersion);
  });
}
