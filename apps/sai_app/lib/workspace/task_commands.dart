import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../commands.dart';

/// The row commands (#72): each goes straight to the store — the
/// projection's own emission updates the lists, so nothing is cached
/// here — and a refusal lands in the notice with the store's reason.
final taskCommandsProvider = Provider<TaskCommands>(TaskCommands.new);

class TaskCommands {
  TaskCommands(this._ref);

  final Ref _ref;

  Future<bool> complete(TaskId task) =>
      _run('complete', (store) => store.completeTask(task));

  Future<bool> cancel(TaskId task) =>
      _run('cancel', (store) => store.cancelTask(task));

  Future<bool> reopen(TaskId task) =>
      _run('reopen', (store) => store.reopenTask(task));

  /// Moves [task] after [after] (first when null) within Today's own order.
  Future<bool> reorderToday(TaskId task, {required TaskId? after}) =>
      _run('reorder', (store) => store.reorderToday(task, after: after));

  /// Moves [task] after [after] (first when null) within its structural
  /// group — Inbox, an area's direct tasks, a project or a heading.
  Future<bool> reorder(TaskId task, {required TaskId? after}) =>
      _run('reorder', (store) => store.reorderTask(task, after: after));

  Future<bool> _run(
    String verb,
    Future<void> Function(TaskStore store) act,
  ) async {
    final notice = _ref.read(noticeProvider.notifier);
    try {
      await act(_ref.read(tasksProvider.notifier).store);
      notice.clear();
      return true;
    } on Object catch (error) {
      notice.show('$verb failed: $error');
      return false;
    }
  }
}
