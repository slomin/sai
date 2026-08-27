import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/assistant/assistant_band.dart';
import 'package:sai_app/commands.dart';
import 'package:sai_app/sidebar.dart';
import 'package:sai_app/workspace/workspace_state.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

void main() {
  /// A workspace to come back to: two areas, a project, a task in it.
  Future<({AreaId work, AreaId home, ProjectId report, TaskId draft})> seed(
    Directory root,
  ) async {
    final archive = await Archive.open(root);
    final store = await TaskStore.open(archive, source: 'sai/test');
    final work = await store.createArea(title: 'Work');
    final home = await store.createArea(title: 'Home');
    final report = await store.createProject(title: 'Q3 report', area: work);
    final draft = await store.createTask(title: 'Draft it', project: report);
    store.dispose();
    await archive.close();
    return (work: work, home: home, report: report, draft: draft);
  }

  Future<void> past(WidgetTester tester) =>
      tester.pump(workspaceSaveDelay + const Duration(milliseconds: 50));

  group('restoring the workspace (#76)', () {
    testWidgets('a valid workspace comes back whole', (tester) async {
      final tmp = tempDir();
      final ids = await seed(Directory('${tmp.path}/archive'));
      File('${tmp.path}/settings.json').writeAsStringSync(
        jsonEncode({
          'version': 0,
          'llm': 'fake',
          'workspace': {
            'section': 'project:${ids.report}',
            'task': '${ids.draft}',
            'collapsed_areas': ['${ids.home}'],
            'assistant_visible': false,
          },
        }),
      );
      final container = await pumpApp(tester, tmp: tmp);
      expect(
        container.read(selectedSectionProvider),
        ProjectSection(ids.report),
      );
      expect(container.read(selectedTaskProvider), ids.draft);
      expect(container.read(collapsedAreasProvider), {ids.home});
      expect(container.read(chatVisibleProvider), isFalse);
      expect(paneTitle(tester), 'Q3 report');
      expect(find.byKey(chatFieldKey), findsNothing);
      expect(sidebarRow(AreaSection(ids.home)), findsOneWidget);
      expect(container.read(noticeProvider), isEmpty);
    });

    testWidgets('a stale section falls back to Today, the task with it', (
      tester,
    ) async {
      final tmp = tempDir();
      final ids = await seed(Directory('${tmp.path}/archive'));
      final file = File('${tmp.path}/settings.json');
      final gone = BlobRef.sha256OfBytes([9, 9, 9]);
      file.writeAsStringSync(
        jsonEncode({
          'version': 0,
          'llm': 'fake',
          'workspace': {
            'section': 'project:$gone',
            'task': '${ids.draft}',
            'collapsed_areas': ['$gone', '${ids.work}'],
          },
        }),
      );
      final container = await pumpApp(tester, tmp: tmp);
      expect(
        container.read(selectedSectionProvider),
        const ListSection(TaskList.today),
      );
      expect(container.read(selectedTaskProvider), isNull);
      expect(container.read(collapsedAreasProvider), {ids.work});
      expect(container.read(chatVisibleProvider), isTrue);
      expect(container.read(noticeProvider), isEmpty);
      // The stale ids are gone from the file once it is rewritten.
      await past(tester);
      final written = jsonDecode(file.readAsStringSync()) as Map;
      expect(written['llm'], 'fake');
      expect(written['workspace'], {
        'assistant_visible': true,
        'collapsed_areas': ['${ids.work}'],
        'section': 'list:today',
      });
    });

    testWidgets('a malformed workspace is ignored, never an error', (
      tester,
    ) async {
      final tmp = tempDir();
      final file = File('${tmp.path}/settings.json');
      file.writeAsStringSync('{"version":0,"llm":"fake","workspace":5}');
      final container = await pumpApp(tester, tmp: tmp);
      expect(
        container.read(selectedSectionProvider),
        const ListSection(TaskList.today),
      );
      expect(container.read(settingsProvider).problem, isNull);
      expect(container.read(settingsProvider).llm, 'fake');
      expect(container.read(noticeProvider), isEmpty);
    });

    testWidgets('an untouched first launch writes nothing', (tester) async {
      final tmp = tempDir();
      await seed(Directory('${tmp.path}/archive'));
      final file = File('${tmp.path}/settings.json');
      await pumpApp(tester, tmp: tmp);
      await past(tester);
      await past(tester);
      expect(file.existsSync(), isFalse, reason: 'nothing moved, no file');
    });

    testWidgets('moving around is remembered, a little after the fact', (
      tester,
    ) async {
      final tmp = tempDir();
      final ids = await seed(Directory('${tmp.path}/archive'));
      final file = File('${tmp.path}/settings.json');
      final container = await pumpApp(tester, tmp: tmp);
      expect(file.existsSync(), isFalse, reason: 'nothing to remember yet');
      await tester.tap(sidebarRow(ProjectSection(ids.report)));
      await tester.pump();
      await tester.tap(find.byKey(sidebarChevronKey(ids.home)));
      await tester.pump();
      expect(container.read(collapsedAreasProvider), {ids.home});
      expect(file.existsSync(), isFalse, reason: 'not yet — one write, later');
      await past(tester);
      expect(jsonDecode(file.readAsStringSync()), {
        'version': 0,
        'llm': null,
        'workspace': {
          'assistant_visible': true,
          'collapsed_areas': ['${ids.home}'],
          'section': 'project:${ids.report}',
        },
      });
      // Nothing changed, nothing written.
      final stamp = file.lastModifiedSync();
      await past(tester);
      expect(file.lastModifiedSync(), stamp);
    });
  });

  group('folding areas (#76)', () {
    testWidgets('the chevron hides an area\'s projects and says so', (
      tester,
    ) async {
      final tmp = tempDir();
      final ids = await seed(Directory('${tmp.path}/archive'));
      await pumpApp(tester, tmp: tmp);
      expect(sidebarRow(ProjectSection(ids.report)), findsOneWidget);
      final chevron = find.byKey(sidebarChevronKey(ids.work));
      expect(find.bySemanticsLabel('Collapse Work'), findsOneWidget);
      await tester.tap(chevron);
      await tester.pump();
      expect(sidebarRow(ProjectSection(ids.report)), findsNothing);
      expect(sidebarRow(AreaSection(ids.work)), findsOneWidget);
      expect(find.bySemanticsLabel('Expand Work'), findsOneWidget);
      expect(find.bySemanticsLabel('Collapse Work'), findsNothing);
      await tester.tap(chevron);
      await tester.pump();
      expect(sidebarRow(ProjectSection(ids.report)), findsOneWidget);
      await past(tester);
    });
  });
}
