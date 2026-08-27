import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'providers_dialog.dart';
import 'widgets/sai_dialog.dart';
import 'workspace/task_commands.dart';

/// Focus for the quick-capture field: Cmd+N and File > New Task land
/// here. Flutter-typed, so app-side rather than in core.
final captureFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode(debugLabel: 'capture');
  ref.onDispose(node.dispose);
  return node;
});

/// Focus for the assistant's input: Cmd+J lands here when it opens.
final chatFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode(debugLabel: 'chat');
  ref.onDispose(node.dispose);
  return node;
});

/// The assistant's draft. Owned here rather than by the band so a
/// half-typed message survives the band being tucked away.
final chatDraftProvider = Provider<TextEditingController>((ref) {
  final controller = TextEditingController();
  ref.onDispose(controller.dispose);
  return controller;
});

/// The top bar's notice: the last failure, or empty once something
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
    required this.toggleInspector,
    required this.completeSelected,
    required this.cancelSelected,
    required this.deleteSelected,
  });

  /// The live handlers, reading through the [ProviderScope] above
  /// [context]. Reads go through the container, not a `WidgetRef`, so an
  /// async handler outliving its widget cannot trip on a disposed ref.
  factory AppCommands.of(BuildContext context) {
    final container = ProviderScope.containerOf(context);
    return AppCommands(
      focusCapture: () => container.read(captureFocusProvider).requestFocus(),
      undo: () => _undo(container),
      toggleChat: () => _toggleChat(container),
      sendChat: () => _sendChat(container),
      cancelChat: () => container.read(chatProvider.notifier).cancel(),
      toggleReasoning: () => _toggleReasoning(container),
      showShortcuts: () => _showShortcuts(context),
      showProviders: () => _showProviders(context),
      select: container.read(selectedSectionProvider.notifier).select,
      toggleInspector: () => _toggleInspector(container),
      completeSelected: () => _completeSelected(container),
      cancelSelected: () => _cancelSelected(container),
      deleteSelected: () => _deleteSelected(context, container),
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

  /// Opens the inspector on the first row of the list when nothing is
  /// selected, or closes it (⌘I). Selection is the inspector's state.
  final VoidCallback toggleInspector;

  /// The Task menu (#74): the selected task, or nothing.
  final VoidCallback completeSelected;
  final VoidCallback cancelSelected;
  final VoidCallback deleteSelected;

  static Future<void> _undo(ProviderContainer container) async {
    if (!container.read(canUndoProvider)) return;
    final notice = container.read(noticeProvider.notifier);
    try {
      await container.read(tasksProvider.notifier).store.undo();
      notice.clear();
    } on Object catch (error) {
      notice.show('undo failed: ${describeFailure(error)}');
    }
  }

  static void _toggleChat(ProviderContainer container) {
    container.read(chatVisibleProvider.notifier).toggle();
    if (!container.read(chatVisibleProvider)) {
      // Tucked away: the list is what is left to type into.
      container.read(captureFocusProvider).requestFocus();
      return;
    }
    // The body mounts on the next frame; focus it once it is there.
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
          .show('could not save the setting: ${describeFailure(error)}');
    }
  }

  static void _toggleInspector(ProviderContainer container) {
    final selection = container.read(selectedTaskProvider.notifier);
    if (container.read(selectedTaskProvider) != null) {
      selection.clear();
      return;
    }
    final section = container.read(selectedSectionProvider);
    final first = container.read(taskViewProvider(section)).value?.tasks;
    if (first != null && first.isNotEmpty) selection.select(first.first.id);
  }

  static Task? _selectedTask(ProviderContainer container) {
    final id = container.read(selectedTaskProvider);
    return id == null ? null : container.read(tasksProvider).value?.task(id);
  }

  static Future<void> _completeSelected(ProviderContainer container) async {
    final task = _selectedTask(container);
    // A task in the Trash keeps its status until it is restored.
    if (task == null || task.deletedAt != null) return;
    final commands = container.read(taskCommandsProvider);
    if (task.status == TaskStatus.open) {
      await commands.complete(task.id);
    } else {
      await commands.reopen(task.id);
    }
  }

  static Future<void> _cancelSelected(ProviderContainer container) async {
    final task = _selectedTask(container);
    if (task == null || task.deletedAt != null) return;
    if (task.status != TaskStatus.open) return;
    await container.read(taskCommandsProvider).cancel(task.id);
  }

  static Future<void> _deleteSelected(
    BuildContext context,
    ProviderContainer container,
  ) async {
    final task = _selectedTask(container);
    if (task == null || task.deletedAt != null) return;
    final answer = await confirmAction(
      context,
      eyebrow: 'Task',
      title: 'Delete “${task.title}”?',
      body: 'It moves to the Trash; the archive keeps its history.',
      confirm: 'Delete',
    );
    if (answer.confirmed) {
      await container.read(taskCommandsProvider).delete(task.id);
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
          '⌘I  Open the inspector on the first row, or close it\n'
          '⌘⏎  Complete the selected task (or reopen it)\n'
          '⌘⌫  Delete the selected task\n'
          '⌘J  Open the assistant, or tuck it away\n'
          '⌘Z  Undo the last change\n'
          '⌘R  Let the model think before it answers, or not\n'
          'Esc  Stop the assistant\'s answer, or leave a field',
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
