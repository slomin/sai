import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../commands.dart';
import 'ordering.dart';

/// The row and inspector commands (#72, #74): each goes straight to the
/// store — the projection's own emission updates the lists, so nothing
/// is cached here — and a refusal lands in the notice with the store's
/// reason.
final taskCommandsProvider = Provider<TaskCommands>(TaskCommands.new);

class TaskCommands {
  TaskCommands(this._ref);

  final Ref _ref;

  Future<bool> complete(TaskId task) =>
      runStoreCommand(_ref, 'complete', (store) => store.completeTask(task));

  Future<bool> cancel(TaskId task) =>
      runStoreCommand(_ref, 'cancel', (store) => store.cancelTask(task));

  Future<bool> reopen(TaskId task) =>
      runStoreCommand(_ref, 'reopen', (store) => store.reopenTask(task));

  Future<bool> delete(TaskId task) =>
      runStoreCommand(_ref, 'delete', (store) => store.deleteTask(task));

  Future<bool> restore(TaskId task) =>
      runStoreCommand(_ref, 'restore', (store) => store.restoreTask(task));

  /// One whole-field edit (#74): the inspector commits a field when it is
  /// left, never per keystroke, so an edit is one undo entry.
  Future<bool> edit(
    TaskId task, {
    Patch<String>? title,
    Patch<String>? notes,
    Patch<TaskWhen>? when,
    Patch<CalendarDate?>? deadline,
    Patch<List<TagId>>? tags,
  }) => runStoreCommand(
    _ref,
    'edit',
    (store) => store.editTask(
      task,
      title: title,
      notes: notes,
      when: when,
      deadline: deadline,
      tags: tags,
    ),
  );

  /// Replaces the whole placement — Inbox when nothing is given.
  Future<bool> move(
    TaskId task, {
    ProjectId? project,
    AreaId? area,
    HeadingId? heading,
  }) => runStoreCommand(
    _ref,
    'move',
    (store) =>
        store.moveTask(task, project: project, area: area, heading: heading),
  );

  /// The Move sheet's two picks (#98), each answering with the refusal's
  /// sentence so the sheet can keep it on screen: a schedule writes one
  /// edit of `when` alone, a place one move.
  Future<String?> trySchedule(TaskId task, TaskWhen when) => tryStoreCommand(
    _ref,
    'schedule',
    (store) => store.editTask(task, when: Patch(when)),
  );

  Future<String?> tryMove(
    TaskId task, {
    ProjectId? project,
    AreaId? area,
    HeadingId? heading,
  }) => tryStoreCommand(
    _ref,
    'move',
    (store) =>
        store.moveTask(task, project: project, area: area, heading: heading),
  );

  Future<bool> setChecklist(TaskId task, List<ChecklistItem> items) =>
      runStoreCommand(
        _ref,
        'checklist',
        (store) => store.setChecklist(task, items),
      );

  /// Moves [task] after [after] (first when null) within Today's own order.
  Future<bool> reorderToday(TaskId task, {required TaskId? after}) =>
      runStoreCommand(
        _ref,
        'reorder',
        (store) => store.reorderToday(task, after: after),
      );

  /// Moves [task] after [after] (first when null) within its structural
  /// group — Inbox, an area's direct tasks, a project or a heading.
  Future<bool> reorder(TaskId task, {required TaskId? after}) =>
      runStoreCommand(
        _ref,
        'reorder',
        (store) => store.reorderTask(task, after: after),
      );

  /// Move up ([by] -1) or Move down (+1) (#98): one step among the open
  /// rows of [task]'s section in [view] — the keyboard's and assistive
  /// tech's way to what a drag does. False, and nothing written, at
  /// either end, for a finished row, or where the view keeps its own
  /// order.
  Future<bool> nudge(TaskId task, int by, {required TaskView view}) {
    for (final section in view.sections) {
      if (!section.tasks.any((t) => t.id == task)) continue;
      if (!reorderable(view, section)) return Future.value(false);
      final ids = [
        for (final t in section.tasks)
          if (t.status == TaskStatus.open) t.id,
      ];
      final anchor = nudgeAnchor(ids, task, by);
      if (!anchor.moves) return Future.value(false);
      return view.section == const ListSection(TaskList.today)
          ? reorderToday(task, after: anchor.after)
          : reorder(task, after: anchor.after);
    }
    return Future.value(false);
  }
}

/// Runs [act] against the open store; a success clears the notice, a
/// refusal shows `<verb> failed: <reason>` and returns false.
Future<bool> runStoreCommand(
  Ref ref,
  String verb,
  Future<void> Function(TaskStore store) act,
) async => await tryStoreCommand(ref, verb, act) == null;

/// The body of [runStoreCommand]: null once the store took [act],
/// otherwise the refusal's own sentence — for a prompt that keeps its
/// line on screen (#96). The notice carries it too, so the top bar keeps
/// the trace after the prompt is gone.
Future<String?> tryStoreCommand(
  Ref ref,
  String verb,
  Future<void> Function(TaskStore store) act,
) async {
  final notice = ref.read(noticeProvider.notifier);
  try {
    await act(ref.read(tasksProvider.notifier).store);
    notice.clear();
    return null;
  } on Object catch (error) {
    final reason = describeFailure(error);
    notice.show('$verb failed: $reason');
    return reason;
  }
}

/// The store's own sentence about a refusal, without the wrapping: a
/// projection error names its reason, an argument error its message.
String describeFailure(Object error) => switch (error) {
  TaskProjectionError(:final reason) => reason,
  ArgumentError(:final message?) => '$message',
  FormatException(:final message) => message,
  StateError(:final message) => message,
  _ => '$error',
};
