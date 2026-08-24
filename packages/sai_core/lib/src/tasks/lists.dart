import 'date.dart';
import 'model.dart';

/// The standard lists v0.1 derives from state. A task's membership is a
/// pure function of the task and today's date — nothing else. Container
/// visibility (hiding tasks whose project or area is deleted) is applied by
/// the projection's queries, not here; see `docs/tasks/task-model-v0.md`.
enum TaskList { inbox, today, upcoming, anytime, someday, logbook }

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
Set<TaskList> listsOf(Task task, CalendarDate today) {
  final primary = listOf(task, today);
  if (primary == null) return const {};
  final lists = {primary};
  if (primary == TaskList.today && _filed(task)) {
    lists.add(TaskList.anytime);
  }
  final deadline = task.deadline;
  if ((primary == TaskList.anytime || primary == TaskList.inbox) &&
      deadline != null &&
      deadline > today) {
    lists.add(TaskList.upcoming);
  }
  return lists;
}

bool _filed(Task task) =>
    task.project != null || task.area != null || task.heading != null;
