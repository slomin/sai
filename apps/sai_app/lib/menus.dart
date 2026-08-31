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
/// [taskSelected] whether the Task menu has a task to act on;
/// [appName] is what the app menu is called — the flavor's display name
/// (ADR 0019), so two running copies can be told apart in the menu bar.
List<PlatformMenuItem> saiMenus({
  required AppCommands commands,
  String appName = 'sai',
  required bool canUndo,
  required bool chatShown,
  required bool reasoningOn,
  required bool taskSelected,
}) => [
  PlatformMenu(
    label: appName,
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
        onSelected: commands.newTask,
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
        label: 'Move / Schedule…',
        shortcut: const SingleActivator(
          LogicalKeyboardKey.keyM,
          meta: true,
          shift: true,
        ),
        onSelected: taskSelected ? commands.moveSelected : null,
      ),
      PlatformMenuItemGroup(
        members: [
          PlatformMenuItem(
            label: 'Move up',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.arrowUp,
              meta: true,
            ),
            onSelected: taskSelected ? commands.moveSelectedUp : null,
          ),
          PlatformMenuItem(
            label: 'Move down',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.arrowDown,
              meta: true,
            ),
            onSelected: taskSelected ? commands.moveSelectedDown : null,
          ),
        ],
      ),
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
      // Ask the assistant for structured suggestions (#35); the lane
      // beside the transcript shows them, nothing changes until Accept.
      PlatformMenuItem(
        label: 'Propose Changes',
        shortcut: const SingleActivator(
          LogicalKeyboardKey.keyP,
          meta: true,
          shift: true,
        ),
        onSelected: commands.proposeChat,
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
  (bool, bool, bool, bool, String)? _menuState;
  List<PlatformMenuItem> _menus = const [];
  // The handler lives on the node: a scope built around a node of its
  // own reads `onKeyEvent` from the node, not the widget.
  late final FocusScopeNode _resting = FocusScopeNode(
    debugLabel: 'workspace',
    // Gated before anything is built: every key from every field passes
    // here on its way up, and only the resting scope's are ours.
    onKeyEvent: (_, event) {
      if (!_resting.hasPrimaryFocus || event is KeyUpEvent) {
        return KeyEventResult.ignored;
      }
      return _arrowed(event) ?? _typed(event);
    },
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
  KeyEventResult _typed(KeyEvent event) {
    // A held key repeats; typing does not open a second Quick Find.
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
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
    AppCommands.of(context).showFind(character);
    return KeyEventResult.handled;
  }

  /// The arrow keys move the selection (#89) — from the resting scope only,
  /// like typing: a field anywhere keeps its own arrows, a dialog is a
  /// route of its own, a native menu takes them before the view does.
  /// Down and repeat both count, so a held key keeps moving; any modifier
  /// makes it something else (⌥→ is a word jump, ⌘↑ a scroll) and it
  /// falls through untouched. Null when it is not an arrow at all.
  KeyEventResult? _arrowed(KeyEvent event) {
    final direction = _arrows[event.logicalKey];
    if (direction == null) return null;
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed ||
        keys.isControlPressed ||
        keys.isAltPressed ||
        keys.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    AppCommands.of(context).navigate(direction);
    return KeyEventResult.handled;
  }

  static final _arrows = {
    LogicalKeyboardKey.arrowUp: NavDirection.up,
    LogicalKeyboardKey.arrowDown: NavDirection.down,
    LogicalKeyboardKey.arrowLeft: NavDirection.left,
    LogicalKeyboardKey.arrowRight: NavDirection.right,
  };

  static final _notTyping = {
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.backspace,
    LogicalKeyboardKey.delete,
    LogicalKeyboardKey.home,
    LogicalKeyboardKey.end,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
  };

  @override
  Widget build(BuildContext context) {
    // Kept alive from launch, so it has seen where a clicked selection
    // stood before that task leaves its list.
    ref.listen(workspaceNavigatorProvider, (_, _) {});
    final commands = AppCommands.of(context);
    final canUndo = ref.watch(canUndoProvider);
    final shown = ref.watch(chatVisibleProvider);
    final reasoning = ref.watch(reasoningProvider);
    final taskSelected = ref.watch(selectedTaskProvider) != null;
    final appName = ref.watch(identityProvider).displayName;
    final state = (canUndo, shown, reasoning, taskSelected, appName);
    if (state != _menuState) {
      _menuState = state;
      _menus = saiMenus(
        commands: commands,
        appName: appName,
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
              commands.newTask,
          const SingleActivator(LogicalKeyboardKey.keyJ, meta: true):
              commands.toggleChat,
          const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
              commands.undo,
          const SingleActivator(LogicalKeyboardKey.escape): commands.cancelChat,
          const SingleActivator(LogicalKeyboardKey.keyR, meta: true):
              commands.toggleReasoning,
          const SingleActivator(
            LogicalKeyboardKey.keyP,
            meta: true,
            shift: true,
          ): commands.proposeChat,
          const SingleActivator(LogicalKeyboardKey.keyI, meta: true):
              commands.toggleInspector,
          const SingleActivator(
            LogicalKeyboardKey.keyM,
            meta: true,
            shift: true,
          ): commands.moveSelected,
          const SingleActivator(LogicalKeyboardKey.arrowUp, meta: true):
              commands.moveSelectedUp,
          const SingleActivator(LogicalKeyboardKey.arrowDown, meta: true):
              commands.moveSelectedDown,
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
