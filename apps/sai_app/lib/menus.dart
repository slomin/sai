import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'commands.dart';
import 'settings/settings_screen.dart';

/// The native menu bar, built in Dart (ADR 0005). The standard items are
/// the platform's own; everything else routes to [commands]. Built to
/// grow: new items slot into these menus rather than new ones.
///
/// The Go menu binds ⌘1–⌘6 to the standard lists and ⌘7 to the Trash
/// (#76); the items keep every list discoverable from the menu bar.
///
/// [chatShown] is whether the assistant's band is open right now;
/// [taskSelected] whether the Task menu has a task to act on.
List<PlatformMenuItem> saiMenus({
  required AppCommands commands,
  required bool canUndo,
  required bool chatShown,
  required bool reasoningOn,
  required bool taskSelected,
}) => [
  PlatformMenu(
    label: 'sai',
    menus: [
      const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
      // Where Settings lives on macOS (#40).
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: 'Settings…',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.comma,
              meta: true,
            ),
            onSelected: () => commands.showSettings(SettingsSection.general),
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
    label: 'Task',
    menus: [
      PlatformMenuItem(
        label: 'Complete',
        shortcut: const SingleActivator(LogicalKeyboardKey.enter, meta: true),
        onSelected: taskSelected ? commands.completeSelected : null,
      ),
      PlatformMenuItem(
        label: 'Cancel',
        shortcut: const SingleActivator(
          LogicalKeyboardKey.enter,
          meta: true,
          alt: true,
        ),
        onSelected: taskSelected ? commands.cancelSelected : null,
      ),
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: 'Delete…',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.backspace,
              meta: true,
            ),
            onSelected: taskSelected ? commands.deleteSelected : null,
          ),
        ],
      ),
    ],
  ),
  PlatformMenu(
    label: 'View',
    menus: [
      PlatformMenuItem(
        label: taskSelected ? 'Hide Inspector' : 'Show Inspector',
        shortcut: const SingleActivator(LogicalKeyboardKey.keyI, meta: true),
        onSelected: commands.toggleInspector,
      ),
      PlatformMenuItem(
        label: chatShown ? 'Hide Assistant' : 'Show Assistant',
        shortcut: const SingleActivator(LogicalKeyboardKey.keyJ, meta: true),
        onSelected: commands.toggleChat,
      ),
      // Whether the model thinks before it answers (and shows it); the
      // same switch as Settings › Providers holds. Platform items carry
      // no checked state (ADR 0005), so the label says which way it goes.
      PlatformMenuItem(
        label: reasoningOn ? 'Disable Reasoning' : 'Enable Reasoning',
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
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: 'Quick Find…',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyK,
              meta: true,
            ),
            onSelected: () => commands.showFind(''),
          ),
        ],
      ),
      for (final list in TaskList.values)
        PlatformMenuItem(
          label: listTitle(list),
          shortcut: SingleActivator(listChord(list), meta: true),
          onSelected: () => commands.select(ListSection(list)),
        ),
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: trashTitle,
            shortcut: const SingleActivator(trashChord, meta: true),
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

/// The digit ⌘-chord of a standard list: ⌘1 Inbox … ⌘6 Logbook, in
/// [TaskList.values] order.
LogicalKeyboardKey listChord(TaskList list) => const [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
][list.index];

/// ⌘7: the Trash, after the six lists.
const trashChord = LogicalKeyboardKey.digit7;

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
///
/// Focus rests on the chrome's own scope (#76): nothing autofocuses at
/// launch, a field that gives focus up lands back here, and a chord
/// reaches the bindings from here — Flutter routes a key up from the
/// primary focus, so with focus above the bindings nothing would fire.
class SaiChrome extends ConsumerStatefulWidget {
  const SaiChrome({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SaiChrome> createState() => _SaiChromeState();
}

class _SaiChromeState extends ConsumerState<SaiChrome> {
  (bool, bool, bool, bool)? _menuState;
  List<PlatformMenuItem> _menus = const [];
  // The handler lives on the node: a scope built around a node of its
  // own reads `onKeyEvent` from the node, not the widget.
  late final _resting = FocusScopeNode(
    debugLabel: 'workspace',
    onKeyEvent: (_, event) => _typed(event, AppCommands.of(context)),
  );

  @override
  void dispose() {
    _resting.dispose();
    super.dispose();
  }

  /// Typing while nothing has the keyboard opens Quick Find on that
  /// character (#76). Only when the resting scope itself is the primary
  /// focus — a field anywhere in the shell keeps its own keys — and only
  /// for a printable character with no ⌘ or ⌃ on it; a chord falls
  /// through to the bindings.
  KeyEventResult _typed(KeyEvent event, AppCommands commands) {
    if (!_resting.hasPrimaryFocus || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed || keys.isControlPressed) {
      return KeyEventResult.ignored;
    }
    final character = event.character;
    if (character == null ||
        character.isEmpty ||
        character.trim().isEmpty ||
        character.codeUnitAt(0) < 0x20 ||
        _notTyping.contains(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    commands.showFind(character);
    return KeyEventResult.handled;
  }

  static final _notTyping = {
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.backspace,
    LogicalKeyboardKey.delete,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.home,
    LogicalKeyboardKey.end,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
  };

  @override
  Widget build(BuildContext context) {
    final commands = AppCommands.of(context);
    final canUndo = ref.watch(canUndoProvider);
    final shown = ref.watch(chatVisibleProvider);
    final reasoning = ref.watch(reasoningProvider);
    final taskSelected = ref.watch(selectedTaskProvider) != null;
    final state = (canUndo, shown, reasoning, taskSelected);
    if (state != _menuState) {
      _menuState = state;
      _menus = saiMenus(
        commands: commands,
        canUndo: canUndo,
        chatShown: shown,
        reasoningOn: reasoning,
        taskSelected: taskSelected,
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
          const SingleActivator(LogicalKeyboardKey.keyI, meta: true):
              commands.toggleInspector,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true):
              commands.completeSelected,
          const SingleActivator(LogicalKeyboardKey.backspace, meta: true):
              commands.deleteSelected,
          const SingleActivator(
            LogicalKeyboardKey.enter,
            meta: true,
            alt: true,
          ): commands.cancelSelected,
          const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
              commands.showSettings(SettingsSection.general),
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
              commands.showFind(''),
          for (final list in TaskList.values)
            SingleActivator(listChord(list), meta: true): () =>
                commands.select(ListSection(list)),
          const SingleActivator(trashChord, meta: true): () =>
              commands.select(const TrashSection()),
        },
        // A scope of its own: a field that gives focus up (Escape, Enter,
        // a click beside it) lands here, inside the bindings, rather than
        // on the route's scope above them.
        child: FocusScope(node: _resting, autofocus: true, child: widget.child),
      ),
    );
  }
}
