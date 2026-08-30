import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/assistant/assistant_band.dart';
import 'package:sai_app/commands.dart';
import 'package:sai_app/menus.dart';
import 'package:sai_app/settings/settings_screen.dart';
import 'package:sai_app/settings/shortcuts_page.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

void main() {
  const topLevel = [
    'sai',
    'File',
    'Edit',
    'Task',
    'View',
    'Go',
    'Window',
    'Help',
  ];

  Map<String, Object?> chord(PlatformMenuItem item) =>
      item.shortcut!.serializeForMenu().toChannelRepresentation();

  group('saiMenus', () {
    final calls = <String>[];
    final commands = AppCommands(
      newTask: () => calls.add('new-task'),
      undo: () => calls.add('undo'),
      toggleChat: () => calls.add('chat'),
      sendChat: () => calls.add('send'),
      cancelChat: () => calls.add('cancel'),
      toggleReasoning: () => calls.add('reasoning'),
      showShortcuts: () => calls.add('shortcuts'),
      showSettings: (section) => calls.add('settings ${section.name}'),
      revealArchive: () => calls.add('reveal'),
      showFind: (seed) => calls.add('find "$seed"'),
      open: (result) => calls.add('open $result'),
      select: (section) => calls.add('select $section'),
      toggleInspector: () => calls.add('inspector'),
      moveSelected: () => calls.add('move'),
      moveSelectedUp: () => calls.add('up'),
      moveSelectedDown: () => calls.add('down'),
      completeSelected: () => calls.add('complete'),
      cancelSelected: () => calls.add('cancel-task'),
      deleteSelected: () => calls.add('delete'),
      navigate: (direction) => calls.add('navigate $direction'),
    );
    List<PlatformMenuItem> menus({
      bool canUndo = false,
      bool chat = true,
      bool task = false,
    }) => saiMenus(
      commands: commands,
      canUndo: canUndo,
      chatShown: chat,
      reasoningOn: false,
      taskSelected: task,
    );

    setUp(calls.clear);

    test('the seven standard menus, in order', () {
      expect(menus().map((m) => m.label), topLevel);
    });

    test('the app and Window menus are platform-provided items', () {
      PlatformProvidedMenuItemType typeOf(PlatformMenuItem item) =>
          (item as PlatformProvidedMenuItem).type;
      final app = menuItem(menus(), ['sai']) as PlatformMenu;
      final appItems = app.menus
          .expand((m) => m is PlatformMenuItemGroup ? m.members : [m])
          .toList();
      expect(
        appItems
            .where((i) => i is! PlatformProvidedMenuItem)
            .map((i) => i.label),
        ['Settings…'],
        reason: 'the one custom item',
      );
      expect(appItems[1].label, 'Settings…', reason: 'after About');
      expect(appItems.whereType<PlatformProvidedMenuItem>().map(typeOf), [
        PlatformProvidedMenuItemType.about,
        PlatformProvidedMenuItemType.servicesSubmenu,
        PlatformProvidedMenuItemType.hide,
        PlatformProvidedMenuItemType.hideOtherApplications,
        PlatformProvidedMenuItemType.showAllApplications,
        PlatformProvidedMenuItemType.quit,
      ]);
      final window = menuItem(menus(), ['Window']) as PlatformMenu;
      expect(
        window.menus
            .expand((m) => m is PlatformMenuItemGroup ? m.members : [m])
            .map(typeOf),
        [
          PlatformProvidedMenuItemType.minimizeWindow,
          PlatformProvidedMenuItemType.zoomWindow,
          PlatformProvidedMenuItemType.arrangeWindowsInFront,
        ],
      );
    });

    test('File > New Task is ⌘N and starts a new task', () {
      final item = menuItem(menus(), ['File', 'New Task']);
      expect(
        chord(item),
        containsPair('shortcutTrigger', LogicalKeyboardKey.keyN.keyId),
      );
      expect(chord(item), containsPair('shortcutModifiers', 1));
      item.onSelected!();
      expect(calls, ['new-task']);
    });

    test('Edit > Undo is ⌘Z, live only with something to undo', () {
      final idle = menuItem(menus(), ['Edit', 'Undo']);
      expect(idle.onSelected, isNull);
      final armed = menuItem(menus(canUndo: true), ['Edit', 'Undo']);
      expect(
        chord(armed),
        containsPair('shortcutTrigger', LogicalKeyboardKey.keyZ.keyId),
      );
      armed.onSelected!();
      expect(calls, ['undo']);
    });

    test('View flips between Hide Assistant and Show Assistant on ⌘J', () {
      final hide = menuItem(menus(chat: true), ['View', 'Hide Assistant']);
      expect(
        chord(hide),
        containsPair('shortcutTrigger', LogicalKeyboardKey.keyJ.keyId),
      );
      hide.onSelected!();
      final show = menuItem(menus(chat: false), ['View', 'Show Assistant']);
      show.onSelected!();
      expect(calls, ['chat', 'chat']);
      final view = menuItem(menus(), ['View']) as PlatformMenu;
      expect(
        (view.menus.last as PlatformMenuItemGroup).members.single,
        isA<PlatformProvidedMenuItem>().having(
          (i) => i.type,
          'type',
          PlatformProvidedMenuItemType.toggleFullScreen,
        ),
      );
    });

    test('Go opens Quick Find on ⌘K, then lists every list and the Trash '
        'on ⌘1–⌘7', () {
      final go = menuItem(menus(), ['Go']) as PlatformMenu;
      final all = go.menus
          .expand((m) => m is PlatformMenuItemGroup ? m.members : [m])
          .toList();
      final find = all.first;
      expect(find.label, 'Quick Find…');
      expect(
        chord(find),
        containsPair('shortcutTrigger', LogicalKeyboardKey.keyK.keyId),
      );
      expect(chord(find), containsPair('shortcutModifiers', 1));
      find.onSelected!();
      expect(calls, ['find ""']);
      calls.clear();
      final items = all.skip(1).toList();
      expect(items.map((i) => i.label), [
        'Inbox',
        'Today',
        'Upcoming',
        'Anytime',
        'Someday',
        'Logbook',
        'Trash',
      ]);
      for (final (i, item) in items.indexed) {
        expect(
          chord(item),
          containsPair('shortcutTrigger', LogicalKeyboardKey.digit1.keyId + i),
          reason: item.label,
        );
        expect(chord(item), containsPair('shortcutModifiers', 1));
      }
      for (final item in items) {
        item.onSelected!();
      }
      expect(calls, [
        for (final list in TaskList.values) 'select ${ListSection(list)}',
        'select ${const TrashSection()}',
      ]);
    });

    test('Help > Keyboard Shortcuts', () {
      menuItem(menus(), ['Help', 'Keyboard Shortcuts']).onSelected!();
      expect(calls, ['shortcuts']);
    });

    test('sai > Settings… on ⌘,', () {
      final item = menuItem(menus(), ['sai', 'Settings…']);
      item.onSelected!();
      expect(calls, ['settings general']);
      expect(
        chord(item),
        containsPair('shortcutTrigger', LogicalKeyboardKey.comma.keyId),
      );
      expect(chord(item), containsPair('shortcutModifiers', 1));
    });

    test('Task > Move / Schedule… on ⇧⌘M, for a selected task only (#98)', () {
      expect(
        menuItem(menus(), ['Task', 'Move / Schedule…']).onSelected,
        isNull,
      );
      final item = menuItem(menus(task: true), ['Task', 'Move / Schedule…']);
      item.onSelected!();
      expect(calls, ['move']);
      expect(
        chord(item),
        containsPair('shortcutTrigger', LogicalKeyboardKey.keyM.keyId),
      );
      // meta and shift, in Flutter's serialisation of the modifier mask.
      expect(chord(item), containsPair('shortcutModifiers', 1 | 2));
    });

    test('Task > Move up and Move down on ⌘↑ and ⌘↓ (#98)', () {
      expect(menuItem(menus(), ['Task', 'Move up']).onSelected, isNull);
      final up = menuItem(menus(task: true), ['Task', 'Move up']);
      final down = menuItem(menus(task: true), ['Task', 'Move down']);
      up.onSelected!();
      down.onSelected!();
      expect(calls, ['up', 'down']);
      expect(
        chord(up),
        containsPair('shortcutTrigger', LogicalKeyboardKey.arrowUp.keyId),
      );
      expect(
        chord(down),
        containsPair('shortcutTrigger', LogicalKeyboardKey.arrowDown.keyId),
      );
      expect(chord(up), containsPair('shortcutModifiers', 1));
    });

    test('Task > Cancel on ⌥⌘⏎', () {
      final item = menuItem(menus(task: true), ['Task', 'Cancel']);
      expect(
        chord(item),
        containsPair('shortcutTrigger', LogicalKeyboardKey.enter.keyId),
      );
      // meta and alt, in Flutter's serialisation of the modifier mask.
      expect(chord(item), containsPair('shortcutModifiers', 1 | 4));
    });
  });

  group('in the app', () {
    testWidgets('the shell publishes the menu bar', (tester) async {
      await pumpApp(tester);
      expect(find.byType(PlatformMenuBar), findsOneWidget);
      expect(menuDelegate.menus.map((m) => m.label), topLevel);
    });

    testWidgets('Go > Inbox switches the main pane', (tester) async {
      final container = await pumpApp(tester);
      await capture(tester, container, 'Buy oat milk');
      expect(find.text('Buy oat milk'), findsNothing);
      menuItem(menuDelegate.menus, ['Go', 'Inbox']).onSelected!();
      await tester.pump();
      expect(paneTitle(tester), 'Inbox');
      expect(find.text('Buy oat milk'), findsOneWidget);
    });

    testWidgets('File > New Task shows the Inbox with capture focused', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      expect(paneTitle(tester), 'Today');
      menuItem(menuDelegate.menus, ['File', 'New Task']).onSelected!();
      await tester.pump();
      await tester.pump();
      expect(paneTitle(tester), 'Inbox');
      expect(container.read(captureFocusProvider).hasFocus, isTrue);
    });

    testWidgets('File > New Task is inert while Settings is up', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      menuItem(menuDelegate.menus, ['sai', 'Settings…']).onSelected!();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(settingsScreenKey), findsOneWidget);
      menuItem(menuDelegate.menus, ['File', 'New Task']).onSelected!();
      await tester.pump();
      await tester.pump();
      expect(find.byKey(settingsScreenKey), findsOneWidget);
      expect(
        container.read(selectedSectionProvider),
        const ListSection(TaskList.today),
      );
      expect(container.read(captureFocusProvider).hasFocus, isFalse);
    });

    testWidgets('Edit > Undo reverses the last capture', (tester) async {
      final container = await pumpApp(tester);
      expect(menuItem(menuDelegate.menus, ['Edit', 'Undo']).onSelected, isNull);
      await capture(tester, container, 'Buy oat milk');
      final undo = menuItem(menuDelegate.menus, ['Edit', 'Undo']);
      expect(undo.onSelected, isNotNull);
      await settleUndo(
        tester,
        container,
        () async => undo.onSelected!(),
        depth: 0,
      );
      expect(container.read(tasksProvider).value!.trash(), hasLength(1));
      expect(menuItem(menuDelegate.menus, ['Edit', 'Undo']).onSelected, isNull);
    });

    testWidgets('View > Hide Assistant tucks the band away, label flips', (
      tester,
    ) async {
      await pumpApp(tester);
      menuItem(menuDelegate.menus, ['View', 'Hide Assistant']).onSelected!();
      await tester.pump();
      expect(find.byKey(chatFieldKey), findsNothing);
      menuItem(menuDelegate.menus, ['View', 'Show Assistant']).onSelected!();
      await tester.pump();
      expect(find.byKey(chatFieldKey), findsOneWidget);
    });

    testWidgets('Help > Keyboard Shortcuts opens Settings on the keys', (
      tester,
    ) async {
      await pumpApp(tester);
      menuItem(menuDelegate.menus, [
        'Help',
        'Keyboard Shortcuts',
      ]).onSelected!();
      await tester.pump();
      expect(find.byType(ShortcutsPage), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ShortcutsPage),
          matching: find.text('⌘J'),
        ),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(settingsScreenKey), findsNothing);
    });
  });
}
