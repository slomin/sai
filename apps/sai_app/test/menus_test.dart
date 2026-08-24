import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/chat_pane.dart';
import 'package:sai_app/commands.dart';
import 'package:sai_app/menus.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

void main() {
  const topLevel = ['sai', 'File', 'Edit', 'View', 'Go', 'Window', 'Help'];

  Map<String, Object?> chord(PlatformMenuItem item) =>
      item.shortcut!.serializeForMenu().toChannelRepresentation();

  group('saiMenus', () {
    final calls = <String>[];
    final commands = AppCommands(
      focusCapture: () => calls.add('capture'),
      undo: () => calls.add('undo'),
      toggleChat: () => calls.add('chat'),
      showShortcuts: () => calls.add('shortcuts'),
      setApiKey: () => calls.add('api key'),
      select: (section) => calls.add('select $section'),
    );
    List<PlatformMenuItem> menus({
      bool canUndo = false,
      bool chat = true,
      bool fits = true,
    }) => saiMenus(
      commands: commands,
      canUndo: canUndo,
      chatShown: chat && fits,
      chatFits: fits,
    );

    setUp(calls.clear);

    test('the seven standard menus, in order', () {
      expect(menus().map((m) => m.label), topLevel);
    });

    test('the app and Window menus are platform-provided items', () {
      PlatformProvidedMenuItemType typeOf(PlatformMenuItem item) =>
          (item as PlatformProvidedMenuItem).type;
      final app = menuItem(menus(), ['sai']) as PlatformMenu;
      expect(
        app.menus
            .expand((m) => m is PlatformMenuItemGroup ? m.members : [m])
            .whereType<PlatformProvidedMenuItem>()
            .map(typeOf),
        [
          PlatformProvidedMenuItemType.about,
          PlatformProvidedMenuItemType.servicesSubmenu,
          PlatformProvidedMenuItemType.hide,
          PlatformProvidedMenuItemType.hideOtherApplications,
          PlatformProvidedMenuItemType.showAllApplications,
          PlatformProvidedMenuItemType.quit,
        ],
      );
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

    test('File > New Task is ⌘N and focuses capture', () {
      final item = menuItem(menus(), ['File', 'New Task']);
      expect(
        chord(item),
        containsPair('shortcutTrigger', LogicalKeyboardKey.keyN.keyId),
      );
      expect(chord(item), containsPair('shortcutModifiers', 1));
      item.onSelected!();
      expect(calls, ['capture']);
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

    test('View flips between Hide Chat and Show Chat on ⌘J', () {
      final hide = menuItem(menus(chat: true), ['View', 'Hide Chat']);
      expect(
        chord(hide),
        containsPair('shortcutTrigger', LogicalKeyboardKey.keyJ.keyId),
      );
      hide.onSelected!();
      final show = menuItem(menus(chat: false), ['View', 'Show Chat']);
      show.onSelected!();
      expect(calls, ['chat', 'chat']);
      // Too narrow for the pane: the item is honest and inert.
      final narrow = menuItem(menus(chat: true, fits: false), [
        'View',
        'Show Chat',
      ]);
      expect(narrow.onSelected, isNull);
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

    test('Go lists every standard list, then the Trash, unbound', () {
      final go = menuItem(menus(), ['Go']) as PlatformMenu;
      final items = go.menus
          .expand((m) => m is PlatformMenuItemGroup ? m.members : [m])
          .toList();
      expect(items.map((i) => i.label), [
        'Inbox',
        'Today',
        'Upcoming',
        'Anytime',
        'Someday',
        'Logbook',
        'Trash',
      ]);
      expect(items.map((i) => i.shortcut), everyElement(isNull));
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

    test('sai > Provider API Key…', () {
      menuItem(menus(), ['sai', 'Provider API Key…']).onSelected!();
      expect(calls, ['api key']);
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
      expect(find.text('Inbox'), findsOneWidget);
      expect(find.text('Buy oat milk'), findsOneWidget);
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

    testWidgets('View > Hide Chat collapses the pane and the label flips', (
      tester,
    ) async {
      await pumpApp(tester);
      menuItem(menuDelegate.menus, ['View', 'Hide Chat']).onSelected!();
      await tester.pump();
      expect(find.byType(ChatPane), findsNothing);
      menuItem(menuDelegate.menus, ['View', 'Show Chat']).onSelected!();
      await tester.pump();
      expect(find.byType(ChatPane), findsOneWidget);
    });

    testWidgets('Help > Keyboard Shortcuts opens the dialog', (tester) async {
      await pumpApp(tester);
      menuItem(menuDelegate.menus, [
        'Help',
        'Keyboard Shortcuts',
      ]).onSelected!();
      await tester.pump();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('⌘J'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
