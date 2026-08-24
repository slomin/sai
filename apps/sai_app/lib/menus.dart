import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'commands.dart';

/// The native menu bar, built in Dart (ADR 0005). The standard items are
/// the platform's own; everything else routes to [commands]. Built to
/// grow: new items slot into these menus rather than new ones.
///
/// The Go menu carries no accelerators yet — list switching by key is
/// deferred until the lists are real (#38); the items keep every list
/// reachable from the keyboard through the menu bar.
List<PlatformMenuItem> saiMenus({
  required AppCommands commands,
  required bool canUndo,
  required bool chatVisible,
}) => [
  PlatformMenu(
    label: 'sai',
    menus: [
      const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
      const PlatformMenuItemGroup(
        members: [
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.servicesSubmenu,
          ),
        ],
      ),
      const PlatformMenuItemGroup(
        members: [
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.hideOtherApplications,
          ),
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.showAllApplications,
          ),
        ],
      ),
      const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
    ],
  ),
  PlatformMenu(
    label: 'File',
    menus: [
      PlatformMenuItem(
        label: 'New Task',
        shortcut: const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
        onSelected: commands.focusCapture,
      ),
    ],
  ),
  PlatformMenu(
    label: 'Edit',
    menus: [
      PlatformMenuItem(
        label: 'Undo',
        shortcut: const SingleActivator(LogicalKeyboardKey.keyZ, meta: true),
        onSelected: canUndo ? commands.undo : null,
      ),
      const PlatformMenuItemGroup(
        members: [
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.startSpeaking,
          ),
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.stopSpeaking,
          ),
        ],
      ),
    ],
  ),
  PlatformMenu(
    label: 'View',
    menus: [
      PlatformMenuItem(
        label: chatVisible ? 'Hide Chat' : 'Show Chat',
        shortcut: const SingleActivator(LogicalKeyboardKey.keyJ, meta: true),
        onSelected: commands.toggleChat,
      ),
      const PlatformMenuItemGroup(
        members: [
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.toggleFullScreen,
          ),
        ],
      ),
    ],
  ),
  PlatformMenu(
    label: 'Go',
    menus: [
      for (final list in TaskList.values)
        PlatformMenuItem(
          label: listTitle(list),
          onSelected: () => commands.select(ListSection(list)),
        ),
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: trashTitle,
            onSelected: () => commands.select(const TrashSection()),
          ),
        ],
      ),
    ],
  ),
  const PlatformMenu(
    label: 'Window',
    menus: [
      PlatformProvidedMenuItem(
        type: PlatformProvidedMenuItemType.minimizeWindow,
      ),
      PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
      PlatformMenuItemGroup(
        members: [
          PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.arrangeWindowsInFront,
          ),
        ],
      ),
    ],
  ),
  PlatformMenu(
    label: 'Help',
    menus: [
      PlatformMenuItem(
        label: 'Keyboard Shortcuts',
        onSelected: commands.showShortcuts,
      ),
    ],
  ),
];

/// The chrome around the shell: the native menu bar and the key bindings,
/// both driving one [AppCommands]. Sits above the shell so its rebuilds
/// are only ever about undo availability and chat visibility, never about
/// what the shell is drawing — each rebuild re-sends the menu.
///
/// A chord bound in both places fires once: on macOS the menu's key
/// equivalent takes it before the Flutter view sees the key; under
/// `flutter test` there is no native menu and the binding takes it.
///
/// Cmd+Z is app undo, not text undo, while there is something to undo —
/// #19's tradeoff, kept. With an empty undo stack the menu item is
/// disabled and the chord is not bound, so it falls through to the
/// focused text field.
class SaiChrome extends ConsumerWidget {
  const SaiChrome({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final commands = AppCommands.of(context);
    final canUndo = ref.watch(canUndoProvider);
    final chatVisible = ref.watch(chatVisibleProvider);
    return PlatformMenuBar(
      menus: saiMenus(
        commands: commands,
        canUndo: canUndo,
        chatVisible: chatVisible,
      ),
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
              commands.focusCapture,
          const SingleActivator(LogicalKeyboardKey.keyJ, meta: true):
              commands.toggleChat,
          if (canUndo)
            const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
                commands.undo,
        },
        child: child,
      ),
    );
  }
}
