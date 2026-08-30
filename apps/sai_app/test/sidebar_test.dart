import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/commands.dart';
import 'package:sai_app/reorder/drag_handle.dart';
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
    // The heading stays, carrying the "+" that adds the first area.
    expect(find.text('AREAS & PROJECTS'), findsOneWidget);
    expect(find.text('ARCHIVED'), findsNothing);
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

  testWidgets('areas and projects drag within their groups by their '
      'handles; across groups a drop is refused (#98)', (tester) async {
    final container = await pumpApp(tester);
    final store = container.read(tasksProvider.notifier).store;
    final ids = await tester.runAsync(() async {
      final home = await store.createArea(title: 'Home');
      final work = await store.createArea(title: 'Work');
      final garden = await store.createProject(title: 'Garden', area: home);
      final kitchen = await store.createProject(title: 'Kitchen', area: home);
      final report = await store.createProject(title: 'Report', area: work);
      final album = await store.createProject(title: 'Album');
      final solo = await store.createProject(title: 'Solo');
      final old = await store.createProject(title: 'Old');
      await store.archiveProject(old);
      return (
        home: home,
        work: work,
        garden: garden,
        kitchen: kitchen,
        report: report,
        album: album,
        solo: solo,
        old: old,
      );
    });
    await tester.pump();
    Finder handleOf(BlobRef id) => find.byKey(dragHandleKey(id));
    expect(
      tester
          .getSemantics(
            find.descendant(
              of: handleOf(ids!.home),
              matching: find.byType(DragHandle),
            ),
          )
          .label,
      'Drag Home',
    );
    // Archived rows carry no handle.
    expect(handleOf(ids.old), findsNothing);

    // An area above another.
    await settleEvents(
      tester,
      container,
      () => dragRow(
        tester,
        handle: handleOf(ids.work),
        source: sidebarRow(AreaSection(ids.work)),
        target: sidebarRow(AreaSection(ids.home)),
        below: false,
      ),
    );
    expect(
      archiveLines(container.read(archiveRootProvider)).last,
      contains('"area.reorder"'),
    );
    expect(store.projection.areaOrder, [ids.work, ids.home]);
    expect(
      tester.getTopLeft(sidebarRow(AreaSection(ids.work))).dy,
      lessThan(tester.getTopLeft(sidebarRow(AreaSection(ids.home))).dy),
    );

    // A project within its area, and a standalone among the standalones.
    await settleEvents(
      tester,
      container,
      () => dragRow(
        tester,
        handle: handleOf(ids.kitchen),
        source: sidebarRow(ProjectSection(ids.kitchen)),
        target: sidebarRow(ProjectSection(ids.garden)),
        below: false,
      ),
    );
    expect(
      archiveLines(container.read(archiveRootProvider)).last,
      contains('"project.reorder"'),
    );
    await settleEvents(
      tester,
      container,
      () => dragRow(
        tester,
        handle: handleOf(ids.solo),
        source: sidebarRow(ProjectSection(ids.solo)),
        target: sidebarRow(ProjectSection(ids.album)),
        below: false,
      ),
    );
    // One sequence serves every group: "first among the standalones" is
    // first of all, and the sidebar reads each group out of it.
    expect(store.projection.projectOrder, [
      ids.solo,
      ids.kitchen,
      ids.garden,
      ids.report,
      ids.album,
      ids.old,
    ]);

    // Garden onto Work's group: no slot, nothing written, the notice.
    final count = store.projection.eventCount;
    final gesture = await dragRow(
      tester,
      handle: handleOf(ids.garden),
      source: sidebarRow(ProjectSection(ids.garden)),
      target: sidebarRow(ProjectSection(ids.report)),
      release: false,
    );
    expect(openGap(), findsNothing);
    await gesture.up();
    await tester.pump();
    await tester.pump();
    expect(store.projection.eventCount, count);
    expect(
      container.read(noticeProvider),
      'reorder failed: a project is ordered within its area',
    );

    // The order survives a replay.
    final replayed = await tester.runAsync(
      () async => TaskStore.open(
        await Archive.open(container.read(archiveRootProvider)),
        source: 'sai/tui',
      ),
    );
    expect(replayed!.projection.areaOrder, [ids.work, ids.home]);
    expect(replayed.projection.projectOrder, store.projection.projectOrder);
    replayed.dispose();
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
