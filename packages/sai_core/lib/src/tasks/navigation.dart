import 'model.dart';
import 'sidebar.dart';

/// The four arrow keys, as a client reports them.
enum NavDirection { up, down, left, right }

/// The sidebar rows a person can land on, top to bottom, as the app
/// draws them (#89): the lists, the Trash, each area followed by its
/// projects unless the area is folded, the standalone projects, then the
/// archived containers. Headings are not rows.
List<SidebarEntry> visibleSidebarRows(
  SidebarModel model,
  Set<AreaId> collapsed,
) => [
  ...model.lists,
  model.trash,
  for (final area in model.areas) ...[
    area.entry,
    if (!collapsed.contains((area.entry.section as AreaSection).area))
      ...area.projects,
  ],
  ...model.projects,
  ...model.archived,
];

/// The row above or below [current] in [rows], staying put at either end.
/// A [current] with no row (a tag view, a container just deleted) enters
/// at the top going down and at the bottom going up. Only up and down are
/// steps; anything else is null.
SidebarSection? stepSection(
  List<SidebarEntry> rows,
  SidebarSection current,
  NavDirection direction,
) {
  if (rows.isEmpty) return null;
  final at = rows.indexWhere((r) => r.section == current);
  return switch (direction) {
    NavDirection.down => rows[at < 0 ? 0 : (at + 1).clamp(0, rows.length - 1)],
    NavDirection.up =>
      rows[at < 0 ? rows.length - 1 : (at - 1).clamp(0, rows.length - 1)],
    _ => null,
  }?.section;
}

/// The task above or below [current] in [tasks] — a view's flat display
/// order, so a step crosses headings — staying put at either end. With
/// nothing selected, down (or right, entering the list) lands on the first
/// row and up on the last. A [current] no longer in the list — completed
/// from Today, say — steps from [lastIndex], where it stood: down lands on
/// the row that took its place, up on the row above; with no memory of
/// where, from the top. Null when the list is empty.
TaskId? stepTask(
  List<Task> tasks,
  TaskId? current,
  NavDirection direction, {
  int? lastIndex,
}) {
  if (tasks.isEmpty) return null;
  final last = tasks.length - 1;
  final at = current == null ? -1 : tasks.indexWhere((t) => t.id == current);
  final int next;
  if (at >= 0) {
    next = switch (direction) {
      NavDirection.down => at + 1,
      NavDirection.up => at - 1,
      _ => at,
    };
  } else if (current != null && lastIndex != null) {
    next = switch (direction) {
      NavDirection.up => lastIndex - 1,
      _ => lastIndex,
    };
  } else {
    next = direction == NavDirection.up ? last : 0;
  }
  return tasks[next.clamp(0, last)].id;
}

/// The row that takes the selection when [id] leaves [tasks]: the one
/// below it, else the one above, else nothing.
TaskId? neighbourOf(List<Task> tasks, TaskId id) {
  final at = tasks.indexWhere((t) => t.id == id);
  if (at < 0) return null;
  if (at + 1 < tasks.length) return tasks[at + 1].id;
  if (at > 0) return tasks[at - 1].id;
  return null;
}
