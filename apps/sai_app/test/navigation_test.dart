import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/assistant/chat_keys.dart';
import 'package:sai_app/commands.dart';
import 'package:sai_app/find/quick_find.dart';
import 'package:sai_app/settings/general_page.dart';
import 'package:sai_app/settings/providers_page.dart';
import 'package:sai_app/settings/settings_screen.dart';
import 'package:sai_app/setup/first_run.dart';
import 'package:sai_app/theme/sai_tokens.dart';
import 'package:sai_app/widgets/sai_dialog.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

Future<void> chord(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
  await tester.pump();
}

Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
  await tester.pump();
}

const up = LogicalKeyboardKey.arrowUp;
const down = LogicalKeyboardKey.arrowDown;
const left = LogicalKeyboardKey.arrowLeft;
const right = LogicalKeyboardKey.arrowRight;

void main() {
  final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);
  const inbox = ListSection(TaskList.inbox);
  const today = ListSection(TaskList.today);

  group('arrow keys (#89)', () {
    testWidgets('↓ and ↑ walk the sidebar, headings and folded rows skipped', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      late AreaId home;
      late ProjectId garden, kitchen, solo, old;
      late TaskId sweep;
      await tester.runAsync(() async {
        home = await store.createArea(title: 'Home');
        garden = await store.createProject(title: 'Garden', area: home);
        kitchen = await store.createProject(title: 'Kitchen', area: home);
        solo = await store.createProject(title: 'Solo');
        old = await store.createProject(title: 'Old');
        await store.archiveProject(old);
        sweep = await store.createTask(title: 'Sweep', area: home);
      });
      await tester.pump();
      SidebarSection section() => container.read(selectedSectionProvider);
      expect(section(), today);
      final walk = <SidebarSection>[
        const ListSection(TaskList.upcoming),
        const ListSection(TaskList.anytime),
        const ListSection(TaskList.someday),
        const ListSection(TaskList.logbook),
        const TrashSection(),
        AreaSection(home),
        ProjectSection(garden),
        ProjectSection(kitchen),
        ProjectSection(solo),
        ProjectSection(old),
      ];
      for (final expected in walk) {
        await key(tester, down);
        expect(section(), expected);
      }
      await key(tester, down);
      expect(section(), ProjectSection(old), reason: 'the end');
      for (final expected in walk.reversed.skip(1)) {
        await key(tester, up);
        expect(section(), expected);
      }
      await key(tester, up);
      expect(section(), today);
      await chord(tester, LogicalKeyboardKey.digit1);
      await key(tester, up);
      expect(section(), inbox, reason: 'the top');

      // Fold Home with ←: its projects leave the walk.
      await selectSection(tester, container, AreaSection(home));
      await key(tester, left);
      expect(container.read(collapsedAreasProvider), {home});
      await key(tester, down);
      expect(section(), ProjectSection(solo));
      await key(tester, up);
      expect(section(), AreaSection(home));
      // → unfolds it; → again enters its list.
      await key(tester, right);
      expect(container.read(collapsedAreasProvider), isEmpty);
      expect(container.read(selectedTaskProvider), isNull);
      await key(tester, right);
      expect(container.read(selectedTaskProvider), sweep);
      // ← leaves the list; the sidebar row is where it was.
      await key(tester, left);
      expect(container.read(selectedTaskProvider), isNull);
      expect(section(), AreaSection(home));
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'workspace');
    }, variant: macOS);

    testWidgets('↓ and ↑ walk a project across its heading and stop', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      late ProjectId project;
      late TaskId a, b, c;
      await tester.runAsync(() async {
        project = await store.createProject(title: 'Garden');
        a = await store.createTask(title: 'Dig', project: project);
        final beds = await store.createHeading(project: project, title: 'Beds');
        b = await store.createTask(
          title: 'Sow',
          project: project,
          heading: beds,
        );
        c = await store.createTask(
          title: 'Water',
          project: project,
          heading: beds,
        );
      });
      await selectSection(tester, container, ProjectSection(project));
      expect(rowTitles(tester), ['Dig', 'Sow', 'Water']);
      TaskId? selected() => container.read(selectedTaskProvider);
      await key(tester, right);
      expect(selected(), a, reason: '→ enters at the first row');
      await key(tester, down);
      expect(selected(), b, reason: 'across the heading');
      await key(tester, down);
      expect(selected(), c);
      await key(tester, down);
      expect(selected(), c, reason: 'the end');
      await key(tester, up);
      await key(tester, up);
      expect(selected(), a);
      await key(tester, up);
      expect(selected(), a, reason: 'the top');
      await key(tester, right);
      expect(selected(), a, reason: '→ in the list does nothing');
      final decoration =
          tester
                  .widget<Container>(
                    find
                        .descendant(
                          of: row(a),
                          matching: find.byType(Container),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      expect(decoration.color, SaiColors.surf, reason: 'shown as selected');
    }, variant: macOS);

    testWidgets('an empty list has nothing to enter', (tester) async {
      final container = await pumpApp(tester);
      await key(tester, right);
      expect(container.read(selectedTaskProvider), isNull);
      await key(tester, down);
      expect(
        container.read(selectedSectionProvider),
        const ListSection(TaskList.upcoming),
        reason: 'the sidebar is still the pane',
      );
      expect(tester.takeException(), isNull);
    }, variant: macOS);

    testWidgets('a completed row steps to the one that took its place', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      late TaskId a, b, c, d;
      await tester.runAsync(() async {
        a = await store.createTask(title: 'a');
        b = await store.createTask(title: 'b');
        c = await store.createTask(title: 'c');
        d = await store.createTask(title: 'd');
      });
      await selectSection(tester, container, inbox);
      TaskId? selected() => container.read(selectedTaskProvider);
      await tester.tap(row(b));
      await tester.pump();
      expect(selected(), b);
      await settleEvents(
        tester,
        container,
        () => chord(tester, LogicalKeyboardKey.enter),
      );
      expect(store.projection.tasks[b]!.status, TaskStatus.completed);
      expect(selected(), b, reason: 'the selection follows the task (#74)');
      expect(rowTitles(tester), ['a', 'c', 'd']);
      await key(tester, down);
      expect(selected(), c, reason: 'the row that took b’s place');
      await tester.tap(row(d));
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => chord(tester, LogicalKeyboardKey.enter),
      );
      expect(rowTitles(tester), ['a', 'c']);
      await key(tester, up);
      expect(selected(), c, reason: 'the row above where d stood');
      await key(tester, up);
      expect(selected(), a);
    }, variant: macOS);

    testWidgets('a deleted row hands the selection to its neighbour', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      late TaskId a, b;
      await tester.runAsync(() async {
        a = await store.createTask(title: 'a');
        b = await store.createTask(title: 'b');
      });
      await selectSection(tester, container, inbox);
      await tester.tap(row(a));
      await tester.pump();
      await chord(tester, LogicalKeyboardKey.backspace);
      expect(find.text('Delete “a”?'), findsOneWidget);
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(dialogPrimaryKey)),
      );
      await tester.pump();
      expect(container.read(selectedTaskProvider), b);
      expect(rowTitles(tester), ['b']);
      await chord(tester, LogicalKeyboardKey.backspace);
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(dialogPrimaryKey)),
      );
      await tester.pump();
      expect(container.read(selectedTaskProvider), isNull, reason: 'alone');
      expect(rowTitles(tester), isEmpty);
    }, variant: macOS);

    testWidgets('switching lists starts the walk from the top', (tester) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      late TaskId a, t;
      await tester.runAsync(() async {
        a = await store.createTask(title: 'a');
        t = await store.createTask(
          title: 't',
          when: TaskWhen.date(container.read(todayProvider)),
        );
      });
      await selectSection(tester, container, inbox);
      await tester.tap(row(a));
      await tester.pump();
      await chord(tester, LogicalKeyboardKey.digit2);
      expect(container.read(selectedTaskProvider), isNull);
      await key(tester, right);
      expect(container.read(selectedTaskProvider), t);
    }, variant: macOS);

    group('focus safety', () {
      testWidgets('a field keeps its arrows', (tester) async {
        final container = await pumpApp(tester);
        final store = container.read(tasksProvider.notifier).store;
        await tester.runAsync(() async {
          await store.createTask(
            title: 't',
            when: TaskWhen.date(container.read(todayProvider)),
          );
        });
        await tester.pump();
        await chord(tester, LogicalKeyboardKey.keyN);
        expect(container.read(captureFocusProvider).hasFocus, isTrue);
        await key(tester, down);
        await key(tester, right);
        expect(container.read(captureFocusProvider).hasFocus, isTrue);
        expect(container.read(selectedSectionProvider), today);
        expect(container.read(selectedTaskProvider), isNull);
        await tester.tap(find.byKey(chatFieldKey));
        await tester.pump();
        expect(container.read(assistantFocusProvider).hasFocus, isTrue);
        await key(tester, down);
        await key(tester, right);
        expect(container.read(assistantFocusProvider).hasFocus, isTrue);
        expect(container.read(selectedSectionProvider), today);
        expect(container.read(selectedTaskProvider), isNull);
      }, variant: macOS);

      testWidgets('Quick Find and Settings keep theirs', (tester) async {
        final container = await pumpApp(tester);
        await chord(tester, LogicalKeyboardKey.keyK);
        expect(find.byKey(quickFindFieldKey), findsOneWidget);
        await key(tester, down);
        expect(container.read(selectedSectionProvider), today);
        expect(find.byKey(quickFindFieldKey), findsOneWidget);
        await key(tester, LogicalKeyboardKey.escape);
        expect(find.byKey(quickFindFieldKey), findsNothing);
        await chord(tester, LogicalKeyboardKey.comma);
        expect(find.byType(GeneralPage), findsOneWidget);
        await key(tester, down);
        expect(find.byType(ProvidersPage), findsOneWidget);
        expect(container.read(selectedSectionProvider), today);
        await key(tester, LogicalKeyboardKey.escape);
        expect(find.byKey(settingsScreenKey), findsNothing);
      }, variant: macOS);

      testWidgets('the first-run gate holds the keys', (tester) async {
        final container = await pumpApp(tester, firstRun: true);
        expect(find.byKey(firstRunKey), findsOneWidget);
        await key(tester, down);
        await key(tester, right);
        expect(container.read(selectedSectionProvider), today);
        expect(container.read(selectedTaskProvider), isNull);
        expect(find.byKey(firstRunKey), findsOneWidget);
      }, variant: macOS);
    });
  });
}
