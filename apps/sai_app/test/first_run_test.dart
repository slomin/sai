import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/commands.dart';
import 'package:sai_app/setup/first_run.dart';
import 'package:sai_app/workspace/task_list_pane.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

void main() {
  group('first run (#40)', () {
    testWidgets('an empty archive and no file: the welcome, over the shell', (
      tester,
    ) async {
      final tmp = tempDir();
      final container = await pumpApp(tester, tmp: tmp, firstRun: true);
      expect(find.byKey(firstRunKey), findsOneWidget);
      expect(find.byKey(captureFieldKey), findsOneWidget, reason: 'behind');
      expect(File('${tmp.path}/settings.json').existsSync(), isFalse);
      await tester.tap(find.byKey(startEmptyKey));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(firstRunKey), findsNothing);
      expect(
        container.read(selectedSectionProvider),
        const ListSection(TaskList.inbox),
      );
      expect(container.read(captureFocusProvider).hasFocus, isTrue);
      expect(container.read(settingsProvider).setupDone, isTrue);
      final written = jsonDecode(
        File('${tmp.path}/settings.json').readAsStringSync(),
      ) as Map;
      expect(written['setup'], 'done');
      // Capture works right away.
      await capture(tester, container, 'Buy oat milk');
      expect(find.text('Buy oat milk'), findsOneWidget);
    });

    testWidgets('setup done in the file: no welcome, ever', (tester) async {
      final tmp = tempDir();
      File('${tmp.path}/settings.json')
          .writeAsStringSync('{"version":0,"llm":null,"setup":"done"}');
      await pumpApp(tester, tmp: tmp, firstRun: true);
      expect(find.byKey(firstRunKey), findsNothing);
    });

    testWidgets('an archive with history: no welcome', (tester) async {
      final tmp = tempDir();
      final archive = await Archive.open(Directory('${tmp.path}/archive'));
      final store = await TaskStore.open(archive, source: 'sai/test');
      await store.createTask(title: 'Buy oat milk');
      store.dispose();
      await archive.close();
      await pumpApp(tester, tmp: tmp, firstRun: true);
      expect(find.byKey(firstRunKey), findsNothing);
    });

    testWidgets('a refused settings write still lets the person through', (
      tester,
    ) async {
      final tmp = tempDir();
      final file = File('${tmp.path}/settings.json')
        ..writeAsStringSync('{"version":9,"llm":"x"}');
      final container = await pumpApp(tester, tmp: tmp, firstRun: true);
      expect(find.byKey(firstRunKey), findsOneWidget);
      expect(find.textContaining('version 9'), findsOneWidget);
      await tester.tap(find.byKey(startEmptyKey));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(firstRunKey), findsNothing);
      expect(container.read(noticeProvider), startsWith('could not save'));
      expect(file.readAsStringSync(), '{"version":9,"llm":"x"}');
    });
  });
}
