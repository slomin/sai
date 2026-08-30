import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/organise/container_menu.dart';
import 'package:sai_app/organise/heading_menu.dart';
import 'package:sai_app/commands.dart';
import 'package:sai_app/organise/tags_dialog.dart';
import 'package:sai_app/reorder/drag_handle.dart';
import 'package:sai_app/workspace/task_section_header.dart';
import 'package:sai_app/widgets/sai_dialog.dart';
import 'package:sai_app/workspace/task_list_pane.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

void main() {
  const inbox = ListSection(TaskList.inbox);
  const today = ListSection(TaskList.today);

  TaskStore storeOf(ProviderContainer c) =>
      c.read(tasksProvider.notifier).store;

  /// Home › Kitchen (two tasks) and Garden; Work (empty area); Album
  /// standalone.
  Future<
    ({
      AreaId home,
      ProjectId kitchen,
      ProjectId garden,
      AreaId work,
      ProjectId album,
    })
  >
  seed(WidgetTester tester, ProviderContainer container) async {
    final store = storeOf(container);
    final ids = await tester.runAsync(() async {
      final home = await store.createArea(title: 'Home');
      final kitchen = await store.createProject(title: 'Kitchen', area: home);
      final garden = await store.createProject(title: 'Garden', area: home);
      final work = await store.createArea(title: 'Work');
      final album = await store.createProject(title: 'Album');
      await store.createTask(title: 'Tiles', project: kitchen);
      await store.createTask(title: 'Paint', project: kitchen);
      return (
        home: home,
        kitchen: kitchen,
        garden: garden,
        work: work,
        album: album,
      );
    });
    await tester.pump();
    return ids!;
  }

  List<String> containerRows(WidgetTester tester) {
    final rows = find
        .byType(ContainerMenu)
        .evaluate()
        .map((e) => (e.widget as ContainerMenu).title)
        .toList();
    return rows;
  }

  Future<void> openMenu(WidgetTester tester, SidebarSection section) async {
    await tester.tap(find.byKey(containerMenuKey(section)));
    await tester.pump();
  }

  Finder item(String label) => find.widgetWithText(MenuItemButton, label);

  /// Taps a menu item and pumps twice: the item fires after the menu has
  /// closed, and a dialog it opens needs the frame after that.
  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(item(label));
    await tester.pump();
    await tester.pump();
  }

  Future<void> typeAndConfirm(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(dialogFieldKey), text);
    await tester.pump();
    await tester.tap(find.byKey(dialogPrimaryKey));
  }

  group('sidebar additions', () {
    testWidgets('+ creates an area and a project, selecting each', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      await tester.tap(find.byKey(sidebarAddKey));
      await tester.pump();
      await choose(tester, 'New area…');
      expect(find.text('New area'), findsOneWidget);
      await settleEvents(
        tester,
        container,
        () => typeAndConfirm(tester, 'Home'),
      );
      final home = storeOf(container).projection.areas.keys.single;
      expect(container.read(selectedSectionProvider), AreaSection(home));
      expect(paneTitle(tester), 'Home');
      expect(sidebarRow(AreaSection(home)), findsOneWidget);

      await tester.tap(find.byKey(sidebarAddKey));
      await tester.pump();
      await choose(tester, 'New project…');
      await settleEvents(
        tester,
        container,
        () => typeAndConfirm(tester, 'Album'),
      );
      final album = storeOf(container).projection.projects.keys.single;
      expect(container.read(selectedSectionProvider), ProjectSection(album));
      expect(containerRows(tester), ['Home', 'Album']);
      final lines = archiveLines(container.read(archiveRootProvider));
      expect(lines.last, contains('"project.create"'));
    });

    testWidgets('a blank name creates nothing; Cancel creates nothing', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      await tester.tap(find.byKey(sidebarAddKey));
      await tester.pump();
      await choose(tester, 'New area…');
      expect(
        tester.widget<SaiPrimaryButton>(find.byKey(dialogPrimaryKey)).onPressed,
        isNull,
      );
      await tester.enterText(find.byKey(dialogFieldKey), '   ');
      await tester.pump();
      expect(
        tester.widget<SaiPrimaryButton>(find.byKey(dialogPrimaryKey)).onPressed,
        isNull,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(storeOf(container).projection.areas, isEmpty);
    });

    testWidgets('two containers may share a title', (tester) async {
      final container = await pumpApp(tester);
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byKey(sidebarAddKey));
        await tester.pump();
        await choose(tester, 'New project…');
        await settleEvents(
          tester,
          container,
          () => typeAndConfirm(tester, 'Album'),
        );
      }
      expect(containerRows(tester), ['Album', 'Album']);
      expect(storeOf(container).projection.projects, hasLength(2));
    });
  });

  group('the container menu', () {
    testWidgets('the sidebar shows the persisted order and nests projects', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      await seed(tester, container);
      expect(containerRows(tester), [
        'Home',
        'Kitchen',
        'Garden',
        'Work',
        'Album',
      ]);
      expect(find.text('ARCHIVED'), findsNothing);
    });

    testWidgets('Rename… writes an edit; the row and the title follow', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      await selectSection(tester, container, ProjectSection(ids.kitchen));
      await openMenu(tester, ProjectSection(ids.kitchen));
      await choose(tester, 'Rename…');
      expect(find.text('Rename “Kitchen”'), findsOneWidget);
      await settleEvents(
        tester,
        container,
        () => typeAndConfirm(tester, 'Kitchen redo'),
      );
      expect(paneTitle(tester), 'Kitchen redo');
      expect(containerRows(tester), contains('Kitchen redo'));
      expect(
        archiveLines(container.read(archiveRootProvider)).last,
        contains('"project.edit"'),
      );
    });

    testWidgets('Move up and Move down reorder within the group only', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      await openMenu(tester, ProjectSection(ids.garden));
      await settleEvents(
        tester,
        container,
        () => tapMenuItem(tester, 'Move up'),
      );
      expect(containerRows(tester), [
        'Home',
        'Garden',
        'Kitchen',
        'Work',
        'Album',
      ]);
      // Already first: nothing to append.
      final count = storeOf(container).projection.eventCount;
      await openMenu(tester, ProjectSection(ids.garden));
      await tester.tap(item('Move up'));
      await tester.pump();
      await tester.pump();
      expect(storeOf(container).projection.eventCount, count);

      await openMenu(tester, AreaSection(ids.home));
      await settleEvents(
        tester,
        container,
        () => tapMenuItem(tester, 'Move down'),
      );
      expect(containerRows(tester), [
        'Work',
        'Home',
        'Garden',
        'Kitchen',
        'Album',
      ]);
      expect(
        archiveLines(container.read(archiveRootProvider)).last,
        contains('"area.reorder"'),
      );
      // Persisted: a second store replays the same order.
      final replayed = await tester.runAsync(() async {
        final archive = await Archive.open(container.read(archiveRootProvider));
        final other = await TaskStore.open(archive, source: 'sai/tui');
        final rows = sidebarModel(
          other.projection,
          today: container.read(todayProvider),
        ).rows.map((e) => e.title).toList();
        other.dispose();
        await archive.close();
        return rows;
      });
      expect(replayed!.sublist(7), [
        'Work',
        'Home',
        'Garden',
        'Kitchen',
        'Album',
      ]);
    });

    testWidgets('Archive puts a project under ARCHIVED, still browsable; '
        'Unarchive brings it back where it was', (tester) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      await selectSection(tester, container, ProjectSection(ids.kitchen));
      await openMenu(tester, ProjectSection(ids.kitchen));
      await settleEvents(
        tester,
        container,
        () => tapMenuItem(tester, 'Archive'),
      );
      // The shell left the project for its area.
      expect(container.read(selectedSectionProvider), AreaSection(ids.home));
      expect(find.text('ARCHIVED'), findsOneWidget);
      expect(containerRows(tester), [
        'Home',
        'Garden',
        'Work',
        'Album',
        'Kitchen',
      ]);
      expect(sidebarCount(tester, inbox), 0);
      expect(
        storeOf(container).projection
            .list(TaskList.anytime, today: container.read(todayProvider)),
        isEmpty,
      );
      // Browsable from the archived row.
      await tester.tap(sidebarRow(ProjectSection(ids.kitchen)));
      await tester.pump();
      expect(paneTitle(tester), 'Kitchen');
      expect(rowTitles(tester), ['Tiles', 'Paint']);

      await openMenu(tester, ProjectSection(ids.kitchen));
      expect(item('Move up'), findsNothing);
      await settleEvents(
        tester,
        container,
        () => tapMenuItem(tester, 'Unarchive'),
      );
      expect(containerRows(tester), [
        'Home',
        'Kitchen',
        'Garden',
        'Work',
        'Album',
      ]);
      expect(find.text('ARCHIVED'), findsNothing);
    });

    testWidgets('archiving an area lists its projects standalone', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      await openMenu(tester, AreaSection(ids.home));
      await settleEvents(
        tester,
        container,
        () => tapMenuItem(tester, 'Archive'),
      );
      expect(containerRows(tester), [
        'Work',
        'Kitchen',
        'Garden',
        'Album',
        'Home',
      ]);
    });

    testWidgets('Delete… offers to move the tasks to the Inbox first', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      await selectSection(tester, container, ProjectSection(ids.kitchen));
      await openMenu(tester, ProjectSection(ids.kitchen));
      await choose(tester, 'Delete…');
      expect(find.text('Delete “Kitchen”?'), findsOneWidget);
      expect(
        find.text('Move its 2 open tasks to the Inbox first'),
        findsOneWidget,
      );
      expect(
        tester.widget<CheckboxListTile>(find.byKey(dialogOptionKey)).value,
        isTrue,
      );
      final depth = storeOf(container).undoDepth;
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(dialogPrimaryKey)),
        count: 3,
      );
      expect(
        storeOf(container).projection.projects[ids.kitchen]!.deletedAt,
        isNotNull,
      );
      expect(sidebarCount(tester, inbox), 2);
      expect(container.read(selectedSectionProvider), AreaSection(ids.home));
      expect(containerRows(tester), ['Home', 'Garden', 'Work', 'Album']);
      // Two moves and a delete: three undo entries.
      expect(storeOf(container).undoDepth, depth + 3);
    });

    testWidgets('with the move turned off the tasks stay put, hidden', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      await openMenu(tester, ProjectSection(ids.kitchen));
      await choose(tester, 'Delete…');
      await tester.tap(find.byKey(dialogOptionKey));
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(dialogPrimaryKey)),
      );
      expect(sidebarCount(tester, inbox), 0);
      final tiles = storeOf(container).projection.tasks.values
          .firstWhere((t) => t.title == 'Tiles');
      expect(tiles.project, ids.kitchen);
    });

    testWidgets('deleting an area keeps its projects, listed standalone', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      await selectSection(tester, container, AreaSection(ids.home));
      await openMenu(tester, AreaSection(ids.home));
      await choose(tester, 'Delete…');
      expect(
        find.byKey(dialogOptionKey),
        findsNothing,
        reason: 'no direct tasks',
      );
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(dialogPrimaryKey)),
      );
      expect(container.read(selectedSectionProvider), today);
      expect(containerRows(tester), ['Work', 'Kitchen', 'Garden', 'Album']);
    });

    testWidgets('a secondary click on the row opens the same menu', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      final gesture = await tester.startGesture(
        tester.getCenter(sidebarRow(ProjectSection(ids.album))),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pump();
      expect(item('Rename…'), findsOneWidget);
      expect(item('New heading…'), findsOneWidget);
      expect(
        tester
            .getSemantics(
              find.descendant(
                of: find.byKey(containerMenuKey(ProjectSection(ids.album))),
                matching: find.byType(InkWell),
              ),
            )
            .label,
        'Options for Album',
      );
    });
  });

  group('headings', () {
    testWidgets('+ HEADING creates one; its menu renames, reorders, deletes', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      await selectSection(tester, container, ProjectSection(ids.kitchen));
      await tester.tap(find.byKey(addHeadingKey));
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => typeAndConfirm(tester, 'Prep'),
      );
      await tester.tap(find.byKey(addHeadingKey));
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => typeAndConfirm(tester, 'Build'),
      );
      final store = storeOf(container);
      final headings = store.projection.headingsOf(ids.kitchen);
      expect(headings.map((h) => h.title), ['Prep', 'Build']);
      expect(find.text('PREP'), findsOneWidget);
      expect(find.text('BUILD'), findsOneWidget);
      final prep = headings.first.id;
      final build = headings.last.id;

      // Move a task under Prep, then rename and reorder the headings.
      final tiles = store.projection.tasks.values.firstWhere(
        (t) => t.title == 'Tiles',
      );
      await settleEvents(
        tester,
        container,
        () => store.moveTask(tiles.id, project: ids.kitchen, heading: prep),
      );
      await tester.tap(find.byKey(headingMenuKey(build)));
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => tapMenuItem(tester, 'Move up'),
      );
      expect(store.projection.headingsOf(ids.kitchen).map((h) => h.title), [
        'Build',
        'Prep',
      ]);
      await tester.tap(find.byKey(headingMenuKey(prep)));
      await tester.pump();
      await choose(tester, 'Rename…');
      await settleEvents(
        tester,
        container,
        () => typeAndConfirm(tester, 'Preparation'),
      );
      expect(find.text('PREPARATION'), findsOneWidget);

      await tester.tap(find.byKey(headingMenuKey(prep)));
      await tester.pump();
      await choose(tester, 'Delete…');
      expect(
        find.text('Keep its 1 open task in the project, unheaded'),
        findsOneWidget,
      );
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(dialogPrimaryKey)),
        count: 2,
      );
      expect(store.projection.headings[prep]!.deletedAt, isNotNull);
      expect(store.projection.tasks[tiles.id]!.heading, isNull);
      expect(store.projection.tasks[tiles.id]!.project, ids.kitchen);
      expect(rowTitles(tester), contains('Tiles'));
    });

    testWidgets('a heading drags below another by its handle; the order '
        'persists through replay; a task dropped on a header is refused '
        '(#98)', (tester) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      final store = storeOf(container);
      final (prep, build) = (await tester.runAsync(() async {
        final prep = await store.createHeading(
          project: ids.kitchen,
          title: 'Prep',
        );
        final build = await store.createHeading(
          project: ids.kitchen,
          title: 'Build',
        );
        return (prep, build);
      }))!;
      container.read(chatVisibleProvider.notifier).toggle();
      await selectSection(tester, container, ProjectSection(ids.kitchen));
      Finder header(HeadingId heading) => find.ancestor(
        of: find.byKey(dragHandleKey(heading)),
        matching: find.byType(TaskSectionHeader),
      );
      expect(
        tester
            .getSemantics(
              find.descendant(
                of: header(prep),
                matching: find.byType(DragHandle),
              ),
            )
            .label,
        'Drag Prep',
      );
      await settleEvents(
        tester,
        container,
        () => dragRow(
          tester,
          handle: find.byKey(dragHandleKey(prep)),
          source: header(prep),
          target: header(build),
        ),
      );
      expect(
        archiveLines(container.read(archiveRootProvider)).last,
        contains('"heading.reorder"'),
      );
      expect(store.projection.headingsOf(ids.kitchen).map((h) => h.title), [
        'Build',
        'Prep',
      ]);
      final replayed = await tester.runAsync(
        () async => TaskStore.open(
          await Archive.open(container.read(archiveRootProvider)),
          source: 'sai/tui',
        ),
      );
      expect(replayed!.projection.headingsOf(ids.kitchen).map((h) => h.title), [
        'Build',
        'Prep',
      ]);
      replayed.dispose();

      // A task's handle over a header: no slot, and a drop says why.
      final tiles = store.projection.tasks.values
          .firstWhere((t) => t.title == 'Tiles')
          .id;
      final count = store.projection.eventCount;
      final gesture = await dragRow(
        tester,
        handle: handle(tiles),
        source: row(tiles),
        target: header(prep),
        release: false,
      );
      expect(openGap(), findsNothing);
      await gesture.up();
      await tester.pump();
      await tester.pump();
      expect(store.projection.eventCount, count);
      expect(
        container.read(noticeProvider),
        'reorder failed: a heading is ordered within its project',
      );
    });

    testWidgets(
      'a heading in an archived project deletes with its tasks kept',
      (tester) async {
        final container = await pumpApp(tester);
        final ids = await seed(tester, container);
        final store = storeOf(container);
        final tiles = store.projection.tasks.values.firstWhere(
          (t) => t.title == 'Tiles',
        );
        final prep = await tester.runAsync(() async {
          final prep = await store.createHeading(
            project: ids.kitchen,
            title: 'Prep',
          );
          await store.moveTask(tiles.id, project: ids.kitchen, heading: prep);
          await store.archiveProject(ids.kitchen);
          return prep;
        });
        await selectSection(tester, container, ProjectSection(ids.kitchen));
        await tester.tap(find.byKey(headingMenuKey(prep!)));
        await tester.pump();
        await choose(tester, 'Delete…');
        await settleEvents(
          tester,
          container,
          () => tester.tap(find.byKey(dialogPrimaryKey)),
          count: 2,
        );
        expect(store.projection.headings[prep]!.deletedAt, isNotNull);
        expect(store.projection.tasks[tiles.id]!.heading, isNull);
        expect(store.projection.tasks[tiles.id]!.project, ids.kitchen);
        expect(rowTitles(tester), contains('Tiles'));
        // An archived project offers no new heading: it would be refused.
        expect(find.byKey(addHeadingKey), findsNothing);
      },
    );

    testWidgets('Return creates the heading exactly like Create', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      await selectSection(tester, container, ProjectSection(ids.kitchen));
      await tester.tap(find.byKey(addHeadingKey));
      await tester.pump();
      await tester.enterText(find.byKey(dialogFieldKey), 'Prep');
      await settleEvents(
        tester,
        container,
        () => tester.testTextInput.receiveAction(TextInputAction.done),
      );
      expect(find.byKey(dialogFieldKey), findsNothing);
      expect(
        storeOf(container).projection
            .headingsOf(ids.kitchen)
            .map((h) => h.title),
        ['Prep'],
      );
      expect(find.text('PREP'), findsOneWidget);
    });

    testWidgets('a blank Return keeps the dialog open and writes nothing', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      final before = storeOf(container).projection.eventCount;
      await selectSection(tester, container, ProjectSection(ids.kitchen));
      await tester.tap(find.byKey(addHeadingKey));
      await tester.pump();
      await tester.enterText(find.byKey(dialogFieldKey), '   ');
      await tester.runAsync(
        () => tester.testTextInput.receiveAction(TextInputAction.done),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(dialogFieldKey), findsOneWidget);
      expect(
        tester.widget<SaiPrimaryButton>(find.byKey(dialogPrimaryKey)).onPressed,
        isNull,
      );
      expect(storeOf(container).projection.eventCount, before);
    });

    testWidgets(
      'New heading… from the sidebar selects the project and shows it',
      (tester) async {
        final container = await pumpApp(tester);
        final ids = await seed(tester, container);
        await selectSection(tester, container, today);
        await openMenu(tester, ProjectSection(ids.kitchen));
        await choose(tester, 'New heading…');
        expect(find.text('New heading'), findsOneWidget);
        await settleEvents(
          tester,
          container,
          () => typeAndConfirm(tester, 'Prep'),
        );
        await tester.pump();
        expect(
          container.read(selectedSectionProvider),
          ProjectSection(ids.kitchen),
        );
        expect(paneTitle(tester), 'Kitchen');
        expect(find.text('PREP'), findsOneWidget);
      },
    );

    testWidgets('a refused heading keeps the draft and says why', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      final store = storeOf(container);
      await selectSection(tester, container, ProjectSection(ids.kitchen));
      await tester.tap(find.byKey(addHeadingKey));
      await tester.pump();
      await tester.enterText(find.byKey(dialogFieldKey), 'Prep');
      // The project goes away underneath the open prompt.
      await settleEvents(
        tester,
        container,
        () => store.archiveProject(ids.kitchen),
      );
      final before = store.projection.eventCount;
      await tester.runAsync(() => tester.tap(find.byKey(dialogPrimaryKey)));
      await settleUntil(
        tester,
        () => find.byKey(dialogErrorKey).evaluate().isNotEmpty,
        () => 'no failure shown',
      );
      expect(find.byKey(dialogFieldKey), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(dialogFieldKey)).controller!.text,
        'Prep',
      );
      expect(
        tester.widget<Text>(find.byKey(dialogErrorKey)).data,
        contains('archived'),
      );
      expect(store.projection.eventCount, before);
      expect(store.projection.headingsOf(ids.kitchen), isEmpty);
      // The field is back in hand, and editing the line retires the
      // sentence about the old one.
      await tester.pump();
      expect(
        tester
            .widget<TextField>(find.byKey(dialogFieldKey))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      await tester.enterText(find.byKey(dialogFieldKey), 'Prep work');
      await tester.pump();
      expect(find.byKey(dialogErrorKey), findsNothing);
      // The draft is still live: Cancel leaves, nothing was written.
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(dialogFieldKey), findsNothing);
    });

    testWidgets('an empty project with a heading shows the heading', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      await selectSection(tester, container, ProjectSection(ids.garden));
      expect(find.text('Garden is empty.'), findsNothing);
      await tester.tap(find.byKey(addHeadingKey));
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => typeAndConfirm(tester, 'Beds'),
      );
      expect(find.text('BEDS'), findsOneWidget);
    });
  });

  group('tags', () {
    testWidgets('the dialog creates, renames and deletes tags', (tester) async {
      final container = await pumpApp(tester);
      final store = storeOf(container);
      final errand = await tester.runAsync(() async {
        final errand = await store.createTag(title: 'errand');
        await store.createTask(title: 'Milk', tags: [errand]);
        return errand;
      });
      await tester.pump();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: TagsDialog()),
        ),
      );
      await tester.pump();
      expect(find.byKey(tagRowKey(errand!)), findsOneWidget);
      expect(find.text('1'), findsOneWidget);

      await tester.tap(find.byKey(newTagKey));
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => typeAndConfirm(tester, 'work'),
      );
      expect(store.projection.tags.values.map((t) => t.title), [
        'errand',
        'work',
      ]);

      await tester.tap(find.byKey(renameTagKey(errand)));
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => typeAndConfirm(tester, 'errands'),
      );
      expect(store.projection.tags[errand]!.title, 'errands');

      await tester.tap(find.byKey(deleteTagKey(errand)));
      await tester.pump();
      expect(find.textContaining('1 open task carries it'), findsOneWidget);
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(dialogPrimaryKey)),
      );
      expect(store.projection.tags[errand]!.deletedAt, isNotNull);
      expect(find.byKey(tagRowKey(errand)), findsNothing);
    });
  });

  group('concurrent change', () {
    testWidgets('another writer\'s containers and order show after reload', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final ids = await seed(tester, container);
      await tester.runAsync(() async {
        final archive = await Archive.open(container.read(archiveRootProvider));
        final other = await TaskStore.open(archive, source: 'sai/tui');
        await other.createProject(title: 'Roof', area: ids.home);
        await other.reorderProject(ids.garden, after: null);
        await other.archiveProject(ids.album);
        other.dispose();
        await archive.close();
        await container.read(tasksProvider.notifier).reload();
      });
      await tester.pump();
      expect(containerRows(tester), [
        'Home',
        'Garden',
        'Kitchen',
        'Roof',
        'Work',
        'Album',
      ]);
      expect(find.text('ARCHIVED'), findsOneWidget);
    });
  });

  group('empty containers', () {
    testWidgets(
      'an empty area shows its empty state and its menu still works',
      (tester) async {
        final container = await pumpApp(tester);
        final ids = await seed(tester, container);
        await selectSection(tester, container, AreaSection(ids.work));
        expect(paneTitle(tester), 'Work');
        expect(rowTitles(tester), isEmpty);
        await openMenu(tester, AreaSection(ids.work));
        await choose(tester, 'New project…');
        await settleEvents(
          tester,
          container,
          () => typeAndConfirm(tester, 'Hiring'),
        );
        expect(containerRows(tester), contains('Hiring'));
        final hiring = storeOf(container).projection.projects.values
            .firstWhere((p) => p.title == 'Hiring');
        expect(hiring.area, ids.work);
        expect(
          container.read(selectedSectionProvider),
          ProjectSection(hiring.id),
        );
      },
    );
  });
}
