import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'find/quick_find.dart';
import 'settings/archive_page.dart' show revealArchiveInFinder;
import 'settings/settings_screen.dart';
import 'workspace/move_sheet.dart';
import 'workspace/task_menu.dart';
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

/// The node above the assistant's body (#76): while focus is anywhere in
/// it — the field, Send, Stop — the Task chords are the assistant's, and
/// [AppCommands] leaves the selected task alone. A plain node, not a
/// scope: a field that lets go of focus falls back to the chrome's
/// resting scope, not to the assistant, so a click on the list is enough
/// to make the chords the task's again.
final assistantFocusProvider = Provider<FocusNode>((ref) {
  final node = FocusNode(
    debugLabel: 'assistant',
    canRequestFocus: false,
    skipTraversal: true,
  );
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

/// A new task starts in the Inbox (#96): the pane switches there so the
/// person sees where the line will land, then capture takes focus — now,
/// and again after the frame the switch schedules, the way [finishSetup]
/// does. Behind the welcome the field cannot take focus (`ExcludeFocus`);
/// under a route above the chrome — Settings, Quick Find, a prompt —
/// focus sits in that route's own scope, which is no ancestor of the
/// field (the native menu item fires there, where the chord is inert).
/// In both cases nothing moves.
void _newTask(ProviderContainer container) {
  final node = container.read(captureFocusProvider);
  if (!node.canRequestFocus) return;
  final primary = FocusManager.instance.primaryFocus;
  if (primary != null && !node.ancestors.contains(primary.nearestScope)) {
    return;
  }
  container
      .read(selectedSectionProvider.notifier)
      .select(const ListSection(TaskList.inbox));
  node.requestFocus();
  WidgetsBinding.instance.addPostFrameCallback((_) => node.requestFocus());
}

/// Every shell command with exactly one handler each, so the menu bar,
/// the key bindings and the buttons steer the same code and cannot
/// double-fire or drift.
class AppCommands {
  const AppCommands({
    required this.newTask,
    required this.undo,
    required this.toggleChat,
    required this.sendChat,
    required this.cancelChat,
    required this.proposeChat,
    required this.acceptSuggestion,
    required this.rejectSuggestion,
    required this.toggleReasoning,
    required this.showShortcuts,
    required this.showSettings,
    required this.revealArchive,
    required this.showFind,
    required this.open,
    required this.select,
    required this.toggleInspector,
    required this.moveSelected,
    required this.moveSelectedUp,
    required this.moveSelectedDown,
    required this.completeSelected,
    required this.cancelSelected,
    required this.deleteSelected,
    required this.navigate,
  });

  /// The live handlers, reading through the [ProviderScope] above
  /// [context]. Reads go through the container, not a `WidgetRef`, so an
  /// async handler outliving its widget cannot trip on a disposed ref.
  factory AppCommands.of(BuildContext context) {
    final container = ProviderScope.containerOf(context);
    return AppCommands(
      newTask: () => _newTask(container),
      undo: () => _undo(container),
      toggleChat: () => _toggleChat(container),
      sendChat: () => _sendChat(container),
      cancelChat: () => container.read(chatProvider.notifier).cancel(),
      proposeChat: () => _proposeChat(container),
      acceptSuggestion: (index) =>
          unawaited(_verdictSuggestion(container, index, accept: true)),
      rejectSuggestion: (index) =>
          unawaited(_verdictSuggestion(container, index, accept: false)),
      toggleReasoning: () => _toggleReasoning(
        container,
        openProviders: () =>
            openSettings(context, initial: SettingsSection.providers),
      ),
      showShortcuts: () =>
          openSettings(context, initial: SettingsSection.shortcuts),
      showSettings: (section) => openSettings(context, initial: section),
      revealArchive: () => revealArchiveInFinder(container),
      showFind: (seed) => showQuickFind(context, seed: seed),
      open: (result) => _open(container, result),
      select: container.read(selectedSectionProvider.notifier).select,
      toggleInspector: () => _toggleInspector(container),
      moveSelected: () => _moveSelected(context, container),
      moveSelectedUp: () => _nudgeSelected(container, -1),
      moveSelectedDown: () => _nudgeSelected(container, 1),
      completeSelected: () => _completeSelected(container),
      cancelSelected: () => _cancelSelected(container),
      deleteSelected: () => _deleteSelected(context, container),
      navigate: container.read(workspaceNavigatorProvider.notifier).move,
    );
  }

  /// ⌘N and File › New Task: the Inbox, with quick capture focused.
  final VoidCallback newTask;
  final VoidCallback undo;
  final VoidCallback toggleChat;

  /// Sends the chat draft as the next turn; the draft clears only when
  /// the send was accepted, so a refused line is not lost.
  final VoidCallback sendChat;

  /// Stops the answer being streamed; a no-op when none is.
  final VoidCallback cancelChat;

  /// Sends the chat draft — or the default request, when it is empty —
  /// as a proposal turn (#35); the lane shows what comes back.
  final VoidCallback proposeChat;

  /// The lane's verdicts (#35); a refusal lands on the top bar.
  final void Function(int index) acceptSuggestion;
  final void Function(int index) rejectSuggestion;

  /// Lets the model think before it answers, or not (`reasoning` in
  /// settings); the thinking shows in the chat pane while it is on. For
  /// a provider with an effort of its own (#26) it opens Settings ›
  /// Providers, where that effort is set.
  final VoidCallback toggleReasoning;

  /// Opens Settings on the Shortcuts page (#40).
  final VoidCallback showShortcuts;

  /// Opens Settings (#40) on a section: ⌘, and sai ▸ Settings… on
  /// General; the same screen hosts the providers.
  final void Function(SettingsSection section) showSettings;

  /// Shows the archive directory in the Finder (Settings › Archive).
  final VoidCallback revealArchive;

  /// Opens Quick Find (#76) with [seed] already typed: the character that
  /// summoned it, or nothing for ⌘K and the menu.
  final void Function(String seed) showFind;

  /// Lands on a Quick Find result: its section, then — for a task — the
  /// task selected there. Section first: the list pane clears a selection
  /// its new section does not show, so the other order loses the task.
  final void Function(FindResult result) open;
  final void Function(SidebarSection) select;

  /// Opens the inspector on the first row of the list when nothing is
  /// selected, or closes it (⌘I). Selection is the inspector's state.
  final VoidCallback toggleInspector;

  /// Task › Move / Schedule… (#98): the sheet on the selected task.
  final VoidCallback moveSelected;

  /// Task › Move up / Move down (#98), ⌘↑ and ⌘↓: one step in the list
  /// being shown, where it can be reordered.
  final VoidCallback moveSelectedUp;
  final VoidCallback moveSelectedDown;

  /// The Task menu (#74): the selected task, or nothing — and nothing
  /// while the assistant holds focus (#76), whichever way the command
  /// arrived, so the menu and the chord cannot disagree.
  final VoidCallback completeSelected;
  final VoidCallback cancelSelected;
  final VoidCallback deleteSelected;

  /// The arrow keys (#89): a row up or down in the sidebar or the list,
  /// into the list or back out of it, an area folded or unfolded.
  final void Function(NavDirection direction) navigate;

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

  static void _proposeChat(ProviderContainer container) {
    final draft = container.read(chatDraftProvider);
    final text = draft.text;
    final chat = container.read(chatProvider.notifier);
    // The same draft-keeping dance as _sendChat; an empty draft is fine
    // here — the notifier substitutes the default request.
    final sending = chat.propose(text);
    if (container.read(chatProvider).error != null) return;
    draft.clear();
    container.read(chatFocusProvider).requestFocus();
    unawaited(
      sending.then((sent) {
        if (!sent && draft.text.isEmpty) draft.text = text;
      }),
    );
  }

  static Future<void> _verdictSuggestion(
    ProviderContainer container,
    int index, {
    required bool accept,
  }) async {
    final proposals = container.read(proposalsProvider.notifier);
    final refusal = accept
        ? await proposals.accept(index)
        : await proposals.reject(index);
    final notice = container.read(noticeProvider.notifier);
    refusal == null ? notice.clear() : notice.show(refusal);
  }

  static void _toggleReasoning(
    ProviderContainer container, {
    required VoidCallback openProviders,
  }) {
    // An OpenAI kind carries its own effort (#26): the chord opens the
    // provider's setting instead of flipping a switch that is not its.
    if (container.read(activeLlmProvider) is ConfiguredEffort) {
      openProviders();
      return;
    }
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

  /// The task a Task command acts on: the selection, unless the assistant
  /// pane has the keyboard — then a chord is a chat keystroke, not a
  /// verdict on a task.
  static Task? _selectedTask(ProviderContainer container) {
    if (container.read(assistantFocusProvider).hasFocus) return null;
    final id = container.read(selectedTaskProvider);
    return id == null ? null : container.read(tasksProvider).value?.task(id);
  }

  static Future<void> _moveSelected(
    BuildContext context,
    ProviderContainer container,
  ) async {
    final task = _selectedTask(container);
    // A task in the Trash is restored first; it has no place to go.
    if (task == null || task.deletedAt != null) return;
    await showMoveSheet(context, task.id);
  }

  static Future<void> _nudgeSelected(
    ProviderContainer container,
    int by,
  ) async {
    final task = _selectedTask(container);
    if (task == null || task.deletedAt != null) return;
    final section = container.read(selectedSectionProvider);
    final view = container.read(taskViewProvider(section)).value;
    if (view == null) return;
    await container.read(taskCommandsProvider).nudge(task.id, by, view: view);
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
    if (!await confirmDeleteTask(context, task)) return;
    // The row below takes the selection (else the one above, else the row
    // standing where the task stood), so the keyboard stays in the list
    // rather than falling back to the sidebar — once the delete has
    // happened; a refused one leaves the selection where it was.
    final section = container.read(selectedSectionProvider);
    final tasks = container.read(taskViewProvider(section)).value?.tasks;
    final next = tasks == null
        ? null
        : container
              .read(workspaceNavigatorProvider.notifier)
              .successorOf(tasks, task.id);
    final ok = await container.read(taskCommandsProvider).delete(task.id);
    if (ok && next != null) {
      container.read(selectedTaskProvider.notifier).select(next);
    }
  }

  static void _open(ProviderContainer container, FindResult result) {
    container.read(selectedSectionProvider.notifier).select(result.section);
    if (result.task case final task?) {
      container.read(selectedTaskProvider.notifier).select(task);
    }
  }
}
