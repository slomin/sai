import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'commands.dart';
import 'shell.dart';

/// The native menu bar, built in Dart (ADR 0005). The standard items are
/// the platform's own; everything else routes to [commands]. Built to
/// grow: new items slot into these menus rather than new ones.
///
/// The Go menu carries no accelerators yet — list switching by key is
/// deferred until the lists are real (#38); the items keep every list
/// reachable from the keyboard through the menu bar.
///
/// [chatShown] is whether the chat pane is on screen right now; [chatFits]
/// whether the window could show it at all — narrower than that, the View
/// item is disabled rather than promising a pane that cannot appear.
List<PlatformMenuItem> saiMenus({
  required AppCommands commands,
  required bool canUndo,
  required bool chatShown,
  required bool chatFits,
  required bool reasoningShown,
}) => [
  PlatformMenu(
    label: 'sai',
    menus: [
      const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
      // Where Settings… goes on macOS; #40 replaces it with the screen.
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: 'Providers…',
            onSelected: commands.showProviders,
          ),
        ],
      ),
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
        label: chatShown ? 'Hide Chat' : 'Show Chat',
        shortcut: const SingleActivator(LogicalKeyboardKey.keyJ, meta: true),
        onSelected: chatFits ? commands.toggleChat : null,
      ),
      // The model's thinking beside its answer; a setting until #40
      // gives it a screen. Platform items carry no checked state (ADR
      // 0005), so the label says which way it goes.
      PlatformMenuItem(
        label: reasoningShown ? 'Hide Reasoning' : 'Show Reasoning',
        shortcut: const SingleActivator(LogicalKeyboardKey.keyR, meta: true),
        onSelected: commands.toggleReasoning,
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
/// are only ever about the menu's own state; the menu tree is rebuilt —
/// and re-sent to the platform — only when that state changes.
///
/// A chord bound in both places fires once: on macOS the menu's key
/// equivalent takes it before the Flutter view sees the key; under
/// `flutter test` there is no native menu and the binding takes it.
///
/// Cmd+Z is always app undo, never the text field's — #19's tradeoff,
/// kept. With an empty undo stack the menu item is disabled, so the chord
/// reaches the binding, which swallows it: otherwise Flutter's own text
/// undo would bring the last captured line back into the field.
class SaiChrome extends ConsumerStatefulWidget {
  const SaiChrome({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SaiChrome> createState() => _SaiChromeState();
}

class _SaiChromeState extends ConsumerState<SaiChrome> {
  (bool, bool, bool, bool)? _menuState;
  List<PlatformMenuItem> _menus = const [];

  @override
  Widget build(BuildContext context) {
    final commands = AppCommands.of(context);
    final canUndo = ref.watch(canUndoProvider);
    final fits = chatFits(context);
    final shown = ref.watch(chatVisibleProvider) && fits;
    final reasoning = ref.watch(showReasoningProvider);
    final state = (canUndo, shown, fits, reasoning);
    if (state != _menuState) {
      _menuState = state;
      _menus = saiMenus(
        commands: commands,
        canUndo: canUndo,
        chatShown: shown,
        chatFits: fits,
        reasoningShown: reasoning,
      );
    }
    return PlatformMenuBar(
      menus: _menus,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyN, meta: true):
              commands.focusCapture,
          const SingleActivator(LogicalKeyboardKey.keyJ, meta: true):
              commands.toggleChat,
          const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
              commands.undo,
          const SingleActivator(LogicalKeyboardKey.escape): commands.cancelChat,
          const SingleActivator(LogicalKeyboardKey.keyR, meta: true):
              commands.toggleReasoning,
        },
        child: widget.child,
      ),
    );
  }
}
