import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/sidebar.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

void main() {
  testWidgets('the sidebar lists every standard list, then the Trash', (
    tester,
  ) async {
    await pumpApp(tester);
    for (final label in [
      'Inbox (0)',
      'Today (0)',
      'Upcoming (0)',
      'Anytime (0)',
      'Someday (0)',
      'Logbook (0)',
      'Trash (0)',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byType(SaiSidebar), findsOneWidget);
  });

  testWidgets('the shell opens on Today; tapping Inbox switches the pane', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    await capture(tester, container, 'Buy oat milk');
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Buy oat milk'), findsNothing);

    await tester.tap(find.text('Inbox (1)'));
    await tester.pump();
    expect(find.text('Inbox'), findsOneWidget);
    expect(find.text('Today'), findsNothing);
    expect(find.text('Buy oat milk'), findsOneWidget);
    expect(
      container.read(selectedSectionProvider),
      const ListSection(TaskList.inbox),
    );
  });

  testWidgets('areas render with their projects nested, then standalones', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    final store = container.read(tasksProvider.notifier).store;
    await tester.runAsync(() async {
      final home = await store.createArea(title: 'Home');
      final garden = await store.createProject(title: 'Garden', area: home);
      await store.createProject(title: 'Album');
      await store.createTask(title: 'plant', project: garden);
      await store.createTask(title: 'dust', area: home);
    });
    await tester.pump();
    expect(find.text('Home (1)'), findsOneWidget);
    expect(find.text('Garden (1)'), findsOneWidget);
    expect(find.text('Album (0)'), findsOneWidget);
    // Projects sit to the right of their area.
    expect(
      tester.getTopLeft(find.text('Garden (1)')).dx,
      greaterThan(tester.getTopLeft(find.text('Home (1)')).dx),
    );
    expect(
      tester.getTopLeft(find.text('Album (0)')).dy,
      greaterThan(tester.getTopLeft(find.text('Garden (1)')).dy),
    );

    await tester.tap(find.text('Garden (1)'));
    await tester.pump();
    expect(find.text('Garden'), findsOneWidget);
    expect(find.text('plant'), findsOneWidget);
    expect(find.text('dust'), findsNothing);
  });

  testWidgets('the selection survives a capture', (tester) async {
    final container = await pumpApp(tester);
    await tester.tap(find.text('Inbox (0)'));
    await tester.pump();
    await capture(tester, container, 'Buy oat milk');
    expect(find.text('Inbox'), findsOneWidget);
    expect(find.text('Buy oat milk'), findsOneWidget);
    expect(find.text('Inbox (1)'), findsOneWidget);
  });

  testWidgets('the selected row is tinted', (tester) async {
    await pumpApp(tester);
    Color? tint(String label) => tester
        .widget<Container>(
          find
              .ancestor(of: find.text(label), matching: find.byType(Container))
              .first,
        )
        .color;
    expect(tint('Today (0)'), isNotNull);
    expect(tint('Inbox (0)'), isNull);
  });
}
