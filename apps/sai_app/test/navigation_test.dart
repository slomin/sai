import 'dart:convert';
import 'dart:io';

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
import 'package:sai_app/sidebar.dart';
import 'package:sai_app/workspace/task_list.dart';
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
      final container = await pumpApp(
        tester,
        finishedTasks: FinishedTaskVisibility.immediate,
      );
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

    testWidgets('a completed row stays selected where it is (#97)', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      late TaskId a, b, c;
      await tester.runAsync(() async {
        a = await store.createTask(title: 'a');
        b = await store.createTask(title: 'b');
        c = await store.createTask(title: 'c');
      });
      await selectSection(tester, container, inbox);
      TaskId? selected() => container.read(selectedTaskProvider);
      await tester.tap(row(b));
      await tester.pump();
      await settleEvents(
        tester,
        container,
        () => chord(tester, LogicalKeyboardKey.enter),
      );
      expect(store.projection.tasks[b]!.status, TaskStatus.completed);
      expect(rowTitles(tester), ['a', 'b', 'c']);
      expect(selected(), b);
      await key(tester, down);
      expect(selected(), c, reason: 'the arrows step over a kept row');
      await key(tester, up);
      expect(selected(), b);
      await key(tester, up);
      expect(selected(), a);
      // ⌘⏎ on the kept row reopens it.
      await key(tester, down);
      await settleEvents(
        tester,
        container,
        () => chord(tester, LogicalKeyboardKey.enter),
      );
      expect(store.projection.tasks[b]!.status, TaskStatus.open);
      expect(rowTitles(tester), ['a', 'b', 'c']);
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

    group('scrolling', () {
      bool within(WidgetTester tester, Finder inner, Finder outer) {
        final a = tester.getRect(inner);
        final b = tester.getRect(outer);
        return a.top >= b.top && a.bottom <= b.bottom;
      }

      testWidgets('the list follows the selection down and back up', (
        tester,
      ) async {
        final container = await pumpApp(tester);
        final store = container.read(tasksProvider.notifier).store;
        final ids = <TaskId>[];
        await tester.runAsync(() async {
          for (var i = 1; i <= 40; i++) {
            ids.add(await store.createTask(title: 'Task $i'));
          }
        });
        await selectSection(tester, container, inbox);
        final list = find.byType(TaskListBody);
        expect(row(ids.last), findsNothing, reason: 'not built yet');
        await key(tester, right);
        for (var i = 1; i < ids.length; i++) {
          await key(tester, down);
          expect(container.read(selectedTaskProvider), ids[i]);
          expect(within(tester, row(ids[i]), list), isTrue, reason: '$i');
        }
        for (var i = ids.length - 2; i >= 0; i--) {
          await key(tester, up);
          expect(within(tester, row(ids[i]), list), isTrue, reason: '$i');
        }
        expect(row(ids.last), findsNothing, reason: 'scrolled away again');
      }, variant: macOS);

      testWidgets('a row scrolled out of reach is found again', (tester) async {
        final container = await pumpApp(tester);
        final store = container.read(tasksProvider.notifier).store;
        final ids = <TaskId>[];
        await tester.runAsync(() async {
          for (var i = 1; i <= 40; i++) {
            ids.add(await store.createTask(title: 'Task $i'));
          }
        });
        await selectSection(tester, container, inbox);
        await key(tester, right);
        expect(container.read(selectedTaskProvider), ids.first);
        final list = find.byType(TaskListBody);
        await tester.drag(
          find.descendant(of: list, matching: find.byType(Scrollable)),
          const Offset(0, -3000),
        );
        await tester.pump();
        expect(row(ids.first), findsNothing, reason: 'unbuilt, far above');
        await key(tester, down);
        await tester.pump();
        expect(container.read(selectedTaskProvider), ids[1]);
        expect(within(tester, row(ids[1]), list), isTrue);
      }, variant: macOS);

      testWidgets('the sidebar follows the selection too', (tester) async {
        final container = await pumpApp(tester);
        final store = container.read(tasksProvider.notifier).store;
        final ids = <ProjectId>[];
        await tester.runAsync(() async {
          for (var i = 1; i <= 30; i++) {
            ids.add(await store.createProject(title: 'Project $i'));
          }
        });
        await tester.pump();
        final sidebar = find.byType(SaiSidebar);
        // Below the fold: not built, the list is lazy.
        expect(
          find.byKey(
            sidebarRowKey(ProjectSection(ids.last)),
            skipOffstage: false,
          ),
          findsNothing,
        );
        await chord(tester, LogicalKeyboardKey.digit7);
        for (final id in ids) {
          await key(tester, down);
          expect(container.read(selectedSectionProvider), ProjectSection(id));
          expect(
            within(tester, sidebarRow(ProjectSection(id)), sidebar),
            isTrue,
          );
        }
        await chord(tester, LogicalKeyboardKey.digit1);
        expect(within(tester, sidebarRow(inbox), sidebar), isTrue);
        // A far row by command, not by a step: the list jumps to it.
        await selectSection(tester, container, ProjectSection(ids.last));
        await tester.pump();
        await tester.pump();
        expect(
          within(tester, sidebarRow(ProjectSection(ids.last)), sidebar),
          isTrue,
        );
      }, variant: macOS);

      testWidgets('a restored selection is brought into view at launch', (
        tester,
      ) async {
        final tmp = tempDir();
        final archive = await Archive.open(Directory('${tmp.path}/archive'));
        final store = await TaskStore.open(archive, source: 'sai/test');
        final ids = <TaskId>[];
        for (var i = 1; i <= 40; i++) {
          ids.add(await store.createTask(title: 'Task $i'));
        }
        store.dispose();
        await archive.close();
        File('${tmp.path}/settings.json').writeAsStringSync(
          jsonEncode({
            'version': 0,
            'workspace': {'section': 'list:inbox', 'task': '${ids[29]}'},
          }),
        );
        final container = await pumpApp(tester, tmp: tmp);
        await tester.pump();
        await tester.pump();
        expect(container.read(selectedTaskProvider), ids[29]);
        expect(within(tester, row(ids[29]), find.byType(TaskListBody)), isTrue);
      }, variant: macOS);

      testWidgets('rows of uneven height are still found', (tester) async {
        final container = await pumpApp(tester);
        final store = container.read(tasksProvider.notifier).store;
        final ids = <TaskId>[];
        await tester.runAsync(() async {
          for (var i = 1; i <= 60; i++) {
            ids.add(
              await store.createTask(
                title: 'Task $i',
                notes: i.isEven ? 'a note line' : '',
              ),
            );
          }
        });
        await selectSection(tester, container, inbox);
        final list = find.byType(TaskListBody);
        // A far row by command (Quick Find would do this): not built.
        expect(row(ids[50]), findsNothing);
        container.read(selectedTaskProvider.notifier).select(ids[50]);
        for (var i = 0; i < 12; i++) {
          await tester.pump();
        }
        expect(within(tester, row(ids[50]), list), isTrue);
      }, variant: macOS);
    });

    testWidgets('an archived area is a plain row: → enters, ← stays put', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      late AreaId old;
      late TaskId t;
      await tester.runAsync(() async {
        old = await store.createArea(title: 'Old');
        t = await store.createTask(title: 'Left behind', area: old);
        await store.archiveArea(old);
      });
      await selectSection(tester, container, AreaSection(old));
      await key(tester, left);
      expect(container.read(collapsedAreasProvider), isEmpty);
      await key(tester, right);
      expect(container.read(collapsedAreasProvider), isEmpty);
      expect(container.read(selectedTaskProvider), t);
    }, variant: macOS);

    testWidgets('a project folded away steps from its area', (tester) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      late AreaId home;
      late ProjectId garden, solo;
      await tester.runAsync(() async {
        home = await store.createArea(title: 'Home');
        garden = await store.createProject(title: 'Garden', area: home);
        solo = await store.createProject(title: 'Solo');
      });
      await selectSection(tester, container, ProjectSection(garden));
      await tester.tap(find.byKey(sidebarChevronKey(home)));
      await tester.pump();
      expect(container.read(collapsedAreasProvider), {home});
      await key(tester, down);
      expect(container.read(selectedSectionProvider), ProjectSection(solo));
    }, variant: macOS);

    testWidgets('a task edited out of the list still hands over on delete', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final store = container.read(tasksProvider.notifier).store;
      final day = container.read(todayProvider);
      late TaskId b, c;
      await tester.runAsync(() async {
        await store.createTask(title: 'a', when: TaskWhen.date(day));
        b = await store.createTask(title: 'b', when: TaskWhen.date(day));
        c = await store.createTask(title: 'c', when: TaskWhen.date(day));
      });
      await tester.pump();
      await tester.tap(row(b));
      await tester.pump();
      // Moved to Someday from the inspector: the selection is kept (#74).
      await tester.runAsync(
        () => store.editTask(b, when: const Patch(TaskWhen.someday)),
      );
      await tester.pump();
      expect(rowTitles(tester), ['a', 'c']);
      expect(container.read(selectedTaskProvider), b);
      await chord(tester, LogicalKeyboardKey.backspace);
      await settleEvents(
        tester,
        container,
        () => tester.tap(find.byKey(dialogPrimaryKey)),
      );
      await tester.pump();
      expect(container.read(selectedTaskProvider), c, reason: 'where b stood');
    }, variant: macOS);

    group('focus safety', () {
      testWidgets('Esc leaves the capture field and the arrows are back', (
        tester,
      ) async {
        final container = await pumpApp(tester);
        await capture(tester, container, 'Captured');
        expect(container.read(captureFocusProvider).hasFocus, isTrue);
        await key(tester, LogicalKeyboardKey.escape);
        expect(container.read(captureFocusProvider).hasFocus, isFalse);
        expect(FocusManager.instance.primaryFocus?.debugLabel, 'workspace');
        await key(tester, down);
        expect(
          container.read(selectedSectionProvider),
          const ListSection(TaskList.upcoming),
        );
      }, variant: macOS);

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
        // ⌘N lands in the Inbox (#96); from there the arrows stay put.
        const inbox = ListSection(TaskList.inbox);
        await chord(tester, LogicalKeyboardKey.keyN);
        expect(container.read(captureFocusProvider).hasFocus, isTrue);
        expect(container.read(selectedSectionProvider), inbox);
        await key(tester, down);
        await key(tester, right);
        expect(container.read(captureFocusProvider).hasFocus, isTrue);
        expect(container.read(selectedSectionProvider), inbox);
        expect(container.read(selectedTaskProvider), isNull);
        await tester.tap(find.byKey(chatFieldKey));
        await tester.pump();
        expect(container.read(assistantFocusProvider).hasFocus, isTrue);
        await key(tester, down);
        await key(tester, right);
        expect(container.read(assistantFocusProvider).hasFocus, isTrue);
        expect(container.read(selectedSectionProvider), inbox);
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
