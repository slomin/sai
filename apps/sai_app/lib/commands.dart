import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'providers_dialog.dart';
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
    required this.sendChat,
    required this.cancelChat,
    required this.toggleReasoning,
    required this.showShortcuts,
    required this.showProviders,
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
      sendChat: () => _sendChat(container),
      cancelChat: () => container.read(chatProvider.notifier).cancel(),
      toggleReasoning: () => _toggleReasoning(container),
      showShortcuts: () => _showShortcuts(context),
      showProviders: () => _showProviders(context),
      select: container.read(selectedSectionProvider.notifier).select,
    );
  }

  final VoidCallback focusCapture;
  final VoidCallback undo;
  final VoidCallback toggleChat;

  /// Sends the chat draft as the next turn; the draft clears only when
  /// the send was accepted, so a refused line is not lost.
  final VoidCallback sendChat;

  /// Stops the answer being streamed; a no-op when none is.
  final VoidCallback cancelChat;

  /// Lets the model think before it answers, or not (`reasoning` in
  /// settings); the thinking shows in the chat pane while it is on.
  final VoidCallback toggleReasoning;
  final VoidCallback showShortcuts;

  /// Opens the providers dialog (`providers_dialog.dart`).
  final VoidCallback showProviders;
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

  static void _sendChat(ProviderContainer container) {
    final draft = container.read(chatDraftProvider);
    final text = draft.text;
    if (text.trim().isEmpty) return;
    final chat = container.read(chatProvider.notifier);
    // A refusal before the first await (busy, no provider, over budget)
    // shows right here and keeps the line. A refusal after it — the
    // archive would not take the message — gives the line back, unless
    // the user has typed something newer meanwhile.
    final sending = chat.send(text);
    if (container.read(chatProvider).error != null) return;
    draft.clear();
    container.read(chatFocusProvider).requestFocus();
    unawaited(
      sending.then((sent) {
        if (!sent && draft.text.isEmpty) draft.text = text;
      }),
    );
  }

  static void _toggleReasoning(ProviderContainer container) {
    final settings = container.read(settingsProvider.notifier);
    final next = !container.read(reasoningProvider);
    try {
      settings.setReasoning(next);
      container
          .read(noticeProvider.notifier)
          .show(next ? 'reasoning on' : 'reasoning off');
    } on Object catch (error) {
      container
          .read(noticeProvider.notifier)
          .show('could not save the setting: $error');
    }
  }

  static void _showProviders(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => const ProvidersDialog(),
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
          '⌘Z  Undo the last change\n'
          '⌘R  Let the model think before it answers, or not\n'
          'Esc  Stop the assistant\'s answer',
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
