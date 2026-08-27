import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/platform/finder.dart';
import 'package:sai_app/settings/archive_page.dart';
import 'package:sai_app/settings/settings_screen.dart';
import 'package:sai_app/setup/first_run.dart';
import 'package:sai_app/things/import_flow.dart';
import 'package:sai_app/widgets/sai_dialog.dart';
import 'package:sai_core/sai_core.dart';
import 'package:sai_core/things_testing.dart';

import 'harness.dart';

/// An open panel that answers with whatever the test says at the time.
final class _Chooser extends FinderPanel {
  const _Chooser(this.path);

  final String? Function() path;

  @override
  Future<String?> chooseFile({required String prompt}) async => path();
}

/// A direct read: no isolate under the widget tester.
Future<ThingsSnapshot> readDirect(String path) async {
  final db = ThingsDatabase.snapshot(path);
  try {
    return db.read();
  } finally {
    db.dispose();
  }
}

String seed(Directory tmp, {int tasks = 2}) {
  final path = '${tmp.path}/main.sqlite';
  final f = ThingsFixture(path);
  final home = f.area('Home');
  final kitchen = f.project('Kitchen', area: home, start: 1);
  for (var i = 0; i < tasks; i++) {
    f.item('Buy oat milk $i', project: kitchen, start: 1);
  }
  f.item('Old', trashed: true);
  f.close();
  return path;
}

/// Every Text on screen.
String screen() => find
    .byType(Text)
    .evaluate()
    .map((e) => (e.widget as Text).data)
    .whereType<String>()
    .join(' | ');

/// Lets real time pass, then pumps, until [ready] holds — the copy, the
/// plan and the appends are real I/O the fake clock cannot drive.
Future<void> until(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out — ${screen()}');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void main() {
  group('the Things import flow (#40)', () {
    testWidgets('first run: preview, import, land in the Inbox', (
      tester,
    ) async {
      final tmp = tempDir();
      final path = seed(tmp);
      final container = await pumpApp(
        tester,
        tmp: tmp,
        firstRun: true,
        overrides: [thingsSnapshotReaderProvider.overrideWithValue(readDirect)],
        // Named by the environment, as a scratch run names it.
        environment: {thingsDatabaseEnv: path},
      );
      await tester.tap(find.byKey(importFromThingsKey));
      await tester.pump();
      // The flow asks for the database after its first frame.
      await tester.pump();
      expect(find.byKey(importFlowKey), findsOneWidget);
      expect(find.byKey(importPreviewKey), findsOneWidget);
      expect(find.textContaining(path), findsOneWidget);
      await tester.tap(find.byKey(importPreviewKey));
      await tester.pump();
      await until(tester, () => find.byKey(importRunKey).evaluate().isNotEmpty);
      expect(find.text('What a run would do'), findsOneWidget);
      expect(find.text('2 new · 0 updated · 0 unchanged'), findsOneWidget);
      expect(find.textContaining('trashed items'), findsOneWidget);
      expect(
        find.text('4 operations would run. Nothing is written yet.'),
        findsOneWidget,
      );
      expect(archiveLines(Directory('${tmp.path}/archive')), isEmpty);
      // Counts only: no title from the database is on screen.
      expect(screen(), isNot(contains('oat milk')));
      await tester.tap(find.byKey(importRunKey));
      await tester.pump();
      await until(
        tester,
        () => find.byKey(importDoneKey).evaluate().isNotEmpty,
      );
      expect(find.text('Imported'), findsOneWidget);
      expect(
        find.text('4 operations, 4 events appended to the archive.'),
        findsOneWidget,
      );
      expect(archiveLines(Directory('${tmp.path}/archive')), hasLength(4));
      await tester.tap(find.byKey(importDoneKey));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(importFlowKey), findsNothing);
      expect(find.byKey(firstRunKey), findsNothing);
      expect(
        container.read(selectedSectionProvider),
        const ListSection(TaskList.inbox),
      );
      expect(container.read(settingsProvider).setupDone, isTrue);
      // The imported tasks are placed in a project, so the Inbox is empty
      // and the project holds them.
      expect(container.read(tasksProvider).value!.tasks, hasLength(2));
    });

    testWidgets('from Settings: a second run has nothing to do', (
      tester,
    ) async {
      final tmp = tempDir();
      final path = seed(tmp);
      final container = await pumpApp(
        tester,
        tmp: tmp,
        firstRun: true,
        overrides: [thingsSnapshotReaderProvider.overrideWithValue(readDirect)],
        environment: {thingsDatabaseEnv: path},
      );
      await tester.tap(find.byKey(startEmptyKey));
      await tester.pump();
      final n = container.read(thingsImportProvider.notifier);
      await tester.runAsync(() async {
        n.locate();
        await n.preview(const ThingsImportOptions());
        await n.run();
        n.reset();
      });
      menuItem(menuDelegate.menus, ['sai', 'Settings…']).onSelected!();
      await tester.pump();
      await tester.tap(find.byKey(settingsNavKey(SettingsSection.archive)));
      await tester.pump();
      await tester.tap(find.byKey(importThingsKey));
      await tester.pump();
      // The flow asks for the database after its first frame.
      await tester.pump();
      await tester.tap(find.byKey(importPreviewKey));
      await tester.pump();
      await until(
        tester,
        () => find.text('Nothing to import').evaluate().isNotEmpty,
      );
      expect(
        tester.widget<SaiPrimaryButton>(find.byKey(importRunKey)).onPressed,
        isNull,
      );
      expect(find.text('2 new · 0 updated · 0 unchanged'), findsNothing);
      expect(find.text('0 new · 0 updated · 2 unchanged'), findsOneWidget);
    });

    testWidgets('the options reach the plan', (tester) async {
      final tmp = tempDir();
      final path = '${tmp.path}/main.sqlite';
      final f = ThingsFixture(path);
      f.item('Open', start: 1);
      f.item('Done', status: 3, stopped: DateTime.utc(2026, 8, 1));
      f.close();
      await pumpApp(
        tester,
        tmp: tmp,
        firstRun: true,
        overrides: [thingsSnapshotReaderProvider.overrideWithValue(readDirect)],
        environment: {thingsDatabaseEnv: path},
      );
      await tester.tap(find.byKey(importFromThingsKey));
      await tester.pump();
      // The flow asks for the database after its first frame.
      await tester.pump();
      await tester.tap(find.byKey(importOpenOnlyKey));
      await tester.pump();
      await tester.tap(find.byKey(importPreviewKey));
      await tester.pump();
      await until(tester, () => find.byKey(importRunKey).evaluate().isNotEmpty);
      expect(find.text('1 new · 0 updated · 0 unchanged'), findsOneWidget);
      expect(find.textContaining('open tasks only'), findsOneWidget);
      expect(find.textContaining('--open-only'), findsNothing);
    });

    testWidgets('no database, a foreign one, a chosen one', (tester) async {
      final tmp = tempDir();
      final foreign = File('${tmp.path}/x.sqlite')..writeAsStringSync('nope');
      final good = seed(tmp, tasks: 1);
      var chosen = foreign.path;
      final container = await pumpApp(
        tester,
        tmp: tmp,
        firstRun: true,
        overrides: [
          thingsSnapshotReaderProvider.overrideWithValue(readDirect),
          finderProvider.overrideWithValue(_Chooser(() => chosen)),
        ],
      );
      await tester.tap(find.byKey(importFromThingsKey));
      await tester.pump();
      // The flow asks for the database after its first frame.
      await tester.pump();
      expect(find.text(const ThingsNotFound().headline), findsOneWidget);
      expect(find.text(const ThingsNotFound().nextAction), findsOneWidget);
      // Choose the foreign file: not a database, with the next step.
      await tester.tap(find.byKey(importChooseKey));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(importPreviewKey), findsOneWidget);
      await tester.tap(find.byKey(importPreviewKey));
      await tester.pump();
      await until(
        tester,
        () => container.read(thingsImportProvider) is ImportFailed,
      );
      expect(find.textContaining('not a Things 3 database'), findsOneWidget);
      expect(find.textContaining('main.sqlite'), findsOneWidget);
      expect(find.byKey(importRetryKey), findsNothing);
      // Then the right one.
      chosen = good;
      await tester.tap(find.byKey(importChooseKey));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(importPreviewKey));
      await tester.pump();
      await until(tester, () => find.byKey(importRunKey).evaluate().isNotEmpty);
      // One area, one project, one task: three rows of one.
      expect(find.text('1 new · 0 updated · 0 unchanged'), findsNWidgets(3));
      // Esc leaves; the plan is forgotten with the dialog.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(importFlowKey), findsNothing);
      expect(find.byKey(firstRunKey), findsOneWidget);
    });

    testWidgets('two ThingsData directories are refused, not guessed', (
      tester,
    ) async {
      final tmp = tempDir();
      for (final data in ['ThingsData-A', 'ThingsData-B']) {
        final dir = Directory(
          '${tmp.path}/$thingsContainerRelative/$data/'
          'Things Database.thingsdatabase',
        )..createSync(recursive: true);
        File('${dir.path}/main.sqlite').writeAsStringSync('');
      }
      await pumpApp(tester, tmp: tmp, firstRun: true);
      await tester.tap(find.byKey(importFromThingsKey));
      await tester.pump();
      // The flow asks for the database after its first frame.
      await tester.pump();
      expect(find.text(const ThingsAmbiguous(2).headline), findsOneWidget);
    });
  });
}
