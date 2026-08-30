import 'package:sai_core/sai_core.dart';

/// Whether the rows of [section] in [view] can be put in a new order:
/// Today (its own order) and every structural group shown on its own —
/// the Inbox, a project's unheaded tasks, a heading, an area's direct
/// tasks. Chronological and hierarchical views keep their order.
bool reorderable(TaskView view, TaskViewSection section) =>
    switch (view.section) {
      ListSection(list: TaskList.today || TaskList.inbox) => true,
      ProjectSection() || AreaSection() =>
        section.kind == TaskViewSectionKind.project ||
            section.kind == TaskViewSectionKind.heading ||
            section.kind == TaskViewSectionKind.area,
      _ => false,
    };

/// Where a nudge lands: whether it moves at all, and the id it lands
/// after (null for first).
typedef NudgeAnchor = ({bool moves, BlobRef? after});

/// The anchor for moving [id] by [by] steps inside [ids] — Move up is
/// -1, Move down +1: the id it lands after, null for first, or no move
/// when it is not in [ids] or already at that end.
NudgeAnchor nudgeAnchor(List<BlobRef> ids, BlobRef id, int by) {
  final index = ids.indexOf(id);
  if (index < 0) return (moves: false, after: null);
  final to = index + by;
  if (to < 0 || to >= ids.length) return (moves: false, after: null);
  final without = [...ids]..removeAt(index);
  return (moves: true, after: to == 0 ? null : without[to - 1]);
}
