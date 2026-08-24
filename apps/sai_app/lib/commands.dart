import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'api_key_dialog.dart';
import 'shell.dart';

/// Focus for the quick-capture field: Cmd+N and File > New Task land
/// here. Flutter-typed, so app-side rather than in core.
final captureFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode(debugLabel: 'capture');
  ref.onDispose(node.dispose);
  return node;
});

/// Focus for the chat pane's input: Cmd+J lands here when it opens.
final chatFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode(debugLabel: 'chat');
  ref.onDispose(node.dispose);
  return node;
});

/// The chat pane's draft. Owned here rather than by the pane so a
/// half-typed message survives the pane unmounting below its breakpoint.
final chatDraftProvider = Provider<TextEditingController>((ref) {
  final controller = TextEditingController();
  ref.onDispose(controller.dispose);
  return controller;
});

/// The status bar's notice: the last failure, or empty once something
/// succeeds again.
final noticeProvider = NotifierProvider<Notice, String>(Notice.new);

class Notice extends Notifier<String> {
  @override
  String build() => '';

  void show(String text) => state = text;

  void clear() => state = '';
}

/// Every shell command with exactly one handler each, so the menu bar,
/// the key bindings and the buttons steer the same code and cannot
/// double-fire or drift.
class AppCommands {
  const AppCommands({
    required this.focusCapture,
    required this.undo,
    required this.toggleChat,
    required this.showShortcuts,
    required this.setApiKey,
    required this.select,
  });

  /// The live handlers, reading through the [ProviderScope] above
  /// [context]. Reads go through the container, not a `WidgetRef`, so an
  /// async handler outliving its widget cannot trip on a disposed ref.
  factory AppCommands.of(BuildContext context) {
    final container = ProviderScope.containerOf(context);
    return AppCommands(
      focusCapture: () => container.read(captureFocusProvider).requestFocus(),
      undo: () => _undo(container),
      toggleChat: () => _toggleChat(container, context),
      showShortcuts: () => _showShortcuts(context),
      setApiKey: () => _setApiKey(context),
      select: container.read(selectedSectionProvider.notifier).select,
    );
  }

  final VoidCallback focusCapture;
  final VoidCallback undo;
  final VoidCallback toggleChat;
  final VoidCallback showShortcuts;

  /// Opens the provider API key dialog (`api_key_dialog.dart`).
  final VoidCallback setApiKey;
  final void Function(SidebarSection) select;

  static Future<void> _undo(ProviderContainer container) async {
    if (!container.read(canUndoProvider)) return;
    final notice = container.read(noticeProvider.notifier);
    try {
      await container.read(tasksProvider.notifier).store.undo();
      notice.clear();
    } on Object catch (error) {
      notice.show('undo failed: $error');
    }
  }

  static void _toggleChat(ProviderContainer container, BuildContext context) {
    // Toggling a pane the window cannot show would only desync the menu
    // from the screen — and a focus request on the unmounted field would
    // latch and steal focus when the pane finally mounts.
    if (!chatFits(context)) {
      container
          .read(noticeProvider.notifier)
          .show('widen the window to show the chat');
      return;
    }
    container.read(chatVisibleProvider.notifier).toggle();
    if (!container.read(chatVisibleProvider)) return;
    // The pane mounts on the next frame; focus it once it is there.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      container.read(chatFocusProvider).requestFocus();
    });
  }

  static void _setApiKey(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => const ApiKeyDialog(),
    );
  }

  static void _showShortcuts(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keyboard Shortcuts'),
        content: const Text(
          '⌘N  New task (focus quick capture)\n'
          '⌘J  Show or hide the chat pane\n'
          '⌘Z  Undo the last change',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
