import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/sidebar.dart';
import 'package:sai_app/theme/sai_tokens.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

void main() {
  const inbox = ListSection(TaskList.inbox);
  const today = ListSection(TaskList.today);

  testWidgets('the sidebar lists every standard list, then the Trash', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.text('LISTS'), findsOneWidget);
    var lastY = 0.0;
    for (final section in [
      for (final list in TaskList.values) ListSection(list),
      const TrashSection(),
    ]) {
      expect(sidebarRow(section), findsOneWidget);
      expect(sidebarCount(tester, section), 0);
      final y = tester.getTopLeft(sidebarRow(section)).dy;
      expect(y, greaterThan(lastY));
      lastY = y;
    }
    expect(find.text('AREAS & PROJECTS'), findsNothing);
    expect(find.byType(SaiSidebar), findsOneWidget);
  });

  testWidgets('the shell opens on Today; tapping Inbox switches the pane', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    await capture(tester, container, 'Buy oat milk');
    expect(paneTitle(tester), 'Today');
    expect(find.text('Buy oat milk'), findsNothing);

    await tester.tap(sidebarRow(inbox));
    await tester.pump();
    expect(paneTitle(tester), 'Inbox');
    expect(find.text('Buy oat milk'), findsOneWidget);
    expect(container.read(selectedSectionProvider), inbox);
  });

  testWidgets('areas render with their projects nested, then standalones', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    final store = container.read(tasksProvider.notifier).store;
    late AreaId home;
    late ProjectId garden;
    late ProjectId album;
    await tester.runAsync(() async {
      home = await store.createArea(title: 'Home');
      garden = await store.createProject(title: 'Garden', area: home);
      album = await store.createProject(title: 'Album');
      await store.createTask(title: 'plant', project: garden);
      await store.createTask(title: 'dust', area: home);
    });
    await tester.pump();
    expect(find.text('AREAS & PROJECTS'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('— Garden'), findsOneWidget);
    expect(find.text('Album'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('— Garden')).dy,
      greaterThan(tester.getTopLeft(find.text('Home')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Album')).dy,
      greaterThan(tester.getTopLeft(find.text('— Garden')).dy),
    );

    await tester.tap(sidebarRow(ProjectSection(garden)));
    await tester.pump();
    expect(paneTitle(tester), 'Garden');
    expect(find.text('plant'), findsOneWidget);
    expect(find.text('dust'), findsNothing);
    expect(sidebarRow(ProjectSection(album)), findsOneWidget);
  });

  testWidgets('the selection survives a capture', (tester) async {
    final container = await pumpApp(tester);
    await tester.tap(sidebarRow(inbox));
    await tester.pump();
    await capture(tester, container, 'Buy oat milk');
    expect(paneTitle(tester), 'Inbox');
    expect(find.text('Buy oat milk'), findsOneWidget);
    expect(sidebarCount(tester, inbox), 1);
  });

  testWidgets('the selected row is ink with a red bar; the rest are bare', (
    tester,
  ) async {
    await pumpApp(tester);
    BoxDecoration decoration(SidebarSection section) =>
        tester
                .widget<Container>(
                  find
                      .descendant(
                        of: sidebarRow(section),
                        matching: find.byType(Container),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    expect(decoration(today).color, SaiColors.ink);
    expect((decoration(today).border! as Border).left.color, SaiColors.red);
    expect(decoration(inbox).color, isNull);
    final row = tester.getSemantics(sidebarRow(today));
    expect(row.label, 'Today, 0');
    expect(row.flagsCollection.isSelected, Tristate.isTrue);
  });

  testWidgets('the sidebar renders in the reference treatment', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final container = await pumpApp(tester);
    final store = container.read(tasksProvider.notifier).store;
    await tester.runAsync(() async {
      final work = await store.createArea(title: 'Work');
      await store.createProject(title: 'Q3 report', area: work);
      await store.createProject(title: 'Website refresh', area: work);
      final home = await store.createArea(title: 'Home');
      await store.createProject(title: 'Kitchen redo', area: home);
      await store.createArea(title: 'Learning');
      await store.createProject(title: 'Read more');
      await store.createTask(
        title: 'Book the dentist',
        when: TaskWhen.date(container.read(todayProvider)),
      );
    });
    await tester.pump();
    await expectLater(
      find.byType(SaiSidebar),
      matchesGoldenFile('goldens/sidebar.png'),
    );
  });
}
