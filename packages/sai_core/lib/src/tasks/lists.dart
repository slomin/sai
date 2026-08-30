import 'date.dart';
import 'model.dart';

/// The standard lists v0.1 derives from state. A task's membership is a
/// pure function of the task and today's date — nothing else. Container
/// visibility (hiding tasks whose project or area is deleted) is applied by
/// the projection's queries, not here; see `docs/tasks/task-model-v0.md`.
enum TaskList { inbox, today, upcoming, anytime, someday, logbook }

/// The display name of a standard list — named once so the clients and
/// the shared view models cannot drift apart.
String listTitle(TaskList list) => switch (list) {
  TaskList.inbox => 'Inbox',
  TaskList.today => 'Today',
  TaskList.upcoming => 'Upcoming',
  TaskList.anytime => 'Anytime',
  TaskList.someday => 'Someday',
  TaskList.logbook => 'Logbook',
};

/// The Trash sits beside the standard lists in every client, but it is a
/// projection query, not a [TaskList] — so its name lives beside, not in,
/// [listTitle].
const trashTitle = 'Trash';

/// When a finished task leaves its working views (#97): a presentation
/// policy over the partition below, shared by both clients through
/// settings (`finished_task_visibility`). Under [endOfDay] a task
/// completed or cancelled on the current local day stays, greyed, in
/// every list and container it would be in if still open — and in the
/// Logbook at once — until local midnight; under [immediate] it leaves
/// on the next frame. Sidebar counts and the assistant's context never
/// include a retained task.
enum FinishedTaskVisibility {
  endOfDay('end_of_day'),
  immediate('immediate');

  const FinishedTaskVisibility(this.wireName);

  /// The word settings hold for this value.
  final String wireName;

  /// The value a settings word names, or null for a word this sai does
  /// not know.
  static FinishedTaskVisibility? fromWire(String word) {
    for (final v in values) {
      if (v.wireName == word) return v;
    }
    return null;
  }
}

/// Whether [task] is a finished task the end-of-day policy keeps in its
/// working views: not deleted, completed or cancelled, and finished on
/// [today] — the finish instant's day in the host's local zone, exactly
/// as the Logbook groups it.
bool isRetained(Task task, CalendarDate today) {
  if (task.deletedAt != null) return false;
  final finished = task.cancelledAt ?? task.completedAt;
  return finished != null && CalendarDate.fromLocal(finished) == today;
}

/// The normative partition: the one list a task belongs to, or null for a
/// deleted task (the Trash is a projection query, not a list).
///
/// First match wins:
///
/// 1. completed or cancelled → logbook
/// 2. deadline ≤ today → today (a due deadline surfaces even from Someday)
/// 3. when is a date ≤ today → today
/// 4. when is someday → someday
/// 5. when is a future date → upcoming
/// 6. unfiled (no project, area or heading) → inbox
/// 7. otherwise → anytime
TaskList? listOf(Task task, CalendarDate today) {
  if (task.deletedAt != null) return null;
  if (task.status != TaskStatus.open) return TaskList.logbook;
  return _workingList(task, today);
}

/// Rules 2–7: where a task belongs by its dates and placement alone.
TaskList _workingList(Task task, CalendarDate today) {
  final deadline = task.deadline;
  if (deadline != null && deadline <= today) return TaskList.today;
  return switch (task.when) {
    TaskWhenDate(:final date) when date <= today => TaskList.today,
    TaskWhenDate() => TaskList.upcoming,
    TaskWhenSomeday() => TaskList.someday,
    TaskWhenNone() => _filed(task) ? TaskList.anytime : TaskList.inbox,
  };
}

/// Every list a task shows up in, Things-style — the partition of [listOf]
/// plus the view unions: a filed Today task is also in Anytime, and an open
/// task with a future deadline also surfaces in Upcoming. Empty for a
/// deleted task.
///
/// Under [FinishedTaskVisibility.endOfDay] a task finished today
/// ([isRetained]) is in the Logbook *and* in every list it would be in if
/// it were still open. The default is the bare partition, so a caller
/// that counts or reasons about open work (the sidebar, the assistant's
/// context) is never handed a finished task by accident.
Set<TaskList> listsOf(
  Task task,
  CalendarDate today, {
  FinishedTaskVisibility visibility = FinishedTaskVisibility.immediate,
}) {
  final primary = listOf(task, today);
  if (primary == null) return const {};
  if (primary == TaskList.logbook) {
    if (visibility == FinishedTaskVisibility.endOfDay &&
        isRetained(task, today)) {
      return {TaskList.logbook, ..._workingLists(task, today)};
    }
    return {TaskList.logbook};
  }
  return _workingLists(task, today);
}

Set<TaskList> _workingLists(Task task, CalendarDate today) {
  final primary = _workingList(task, today);
  final lists = {primary};
  if (primary == TaskList.today && _filed(task)) {
    lists.add(TaskList.anytime);
  }
  final deadline = task.deadline;
  if (deadline != null && deadline > today) {
    lists.add(TaskList.upcoming);
  }
  return lists;
}

bool _filed(Task task) =>
    task.project != null || task.area != null || task.heading != null;
