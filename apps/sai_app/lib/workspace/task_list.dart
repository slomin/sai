import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../theme/sai_tokens.dart';
import 'dates.dart';
import 'task_commands.dart';
import 'task_row.dart';
import 'task_row_chips.dart';
import 'task_section_header.dart';

/// Whether the rows of [section] in [view] can be dragged into a new
/// order: Today (its own order) and every structural group shown on its
/// own — the Inbox, a project's unheaded tasks, a heading, an area's
/// direct tasks. Chronological and hierarchical views keep their order.
bool reorderable(TaskView view, TaskViewSection section) =>
    switch (view.section) {
      ListSection(list: TaskList.today || TaskList.inbox) => true,
      ProjectSection() || AreaSection() =>
        section.kind == TaskViewSectionKind.project ||
            section.kind == TaskViewSectionKind.heading ||
            section.kind == TaskViewSectionKind.area,
      _ => false,
    };

/// A row that has just left [TaskView] but is still on screen, finishing
/// where it was.
final class _Ghost {
  _Ghost(this.task, this.section, this.index, this.finish);

  final Task task;
  final int section;
  final int index;
  final RowFinish finish;
}

/// A list item: a live task, or the ghost of one that just finished.
final class _Item {
  const _Item(this.task, {this.ghost});

  final Task task;
  final _Ghost? ghost;
}

String _meta(int count) => count == 1 ? '1 TASK' : '$count TASKS';

/// The sections of a [TaskView] as slivers: a header where the group is
/// named, then its rows — reorderable where [reorderable] says so.
class TaskListBody extends ConsumerStatefulWidget {
  const TaskListBody({
    super.key,
    required this.view,
    required this.projection,
    required this.today,
  });

  final TaskView view;
  final TaskProjection projection;
  final CalendarDate today;

  @override
  ConsumerState<TaskListBody> createState() => _TaskListBodyState();
}

class _TaskListBodyState extends ConsumerState<TaskListBody> {
  final _ghosts = <TaskId, _Ghost>{};
  var _known = <TaskId>{};
  var _entering = <TaskId>{};
  SidebarSection? _knownSection;

  @override
  void didUpdateWidget(TaskListBody old) {
    super.didUpdateWidget(old);
    final ids = {for (final t in widget.view.tasks) t.id};
    // A new task in the same view grows in; switching lists just shows.
    _entering = widget.view.section == _knownSection
        ? ids.difference(_known)
        : const {};
    _known = ids;
    _knownSection = widget.view.section;
    // A ghost whose task is back in the view (undo) gives way to the row.
    _ghosts.removeWhere((id, _) => ids.contains(id));
  }

  @override
  void initState() {
    super.initState();
    _known = {for (final t in widget.view.tasks) t.id};
    _knownSection = widget.view.section;
  }

  Future<void> _finish(
    Task task,
    int section,
    int index,
    RowFinish finish,
  ) async {
    final commands = ref.read(taskCommandsProvider);
    final logbook = widget.view.section == const ListSection(TaskList.logbook);
    if (logbook) {
      // Reopening from the Logbook: the row simply leaves.
      await commands.reopen(task.id);
      return;
    }
    setState(() => _ghosts[task.id] = _Ghost(task, section, index, finish));
    final ok = finish == RowFinish.completed
        ? await commands.complete(task.id)
        : await commands.cancel(task.id);
    if (!ok && mounted) setState(() => _ghosts.remove(task.id));
  }

  List<_Item> _items(int sectionIndex, TaskViewSection section) {
    final items = [for (final t in section.tasks) _Item(t)];
    final ghosts =
        _ghosts.values.where((g) => g.section == sectionIndex).toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    for (final ghost in ghosts) {
      final at = ghost.index.clamp(0, items.length);
      items.insert(at, _Item(ghost.task, ghost: ghost));
    }
    return items;
  }

  Future<void> _reorder(
    TaskViewSection section,
    List<_Item> items,
    int oldIndex,
    int newIndex,
  ) async {
    // [newIndex] is already the slot after removal (onReorderItem).
    final ids = [for (final item in items) item.task.id];
    final moved = ids.removeAt(oldIndex);
    final to = newIndex;
    ids.insert(to, moved);
    // The anchor is the nearest live row above the drop slot.
    TaskId? after;
    for (var i = to - 1; i >= 0; i--) {
      if (_ghosts.containsKey(ids[i])) continue;
      after = ids[i];
      break;
    }
    final commands = ref.read(taskCommandsProvider);
    if (widget.view.section == const ListSection(TaskList.today)) {
      await commands.reorderToday(moved, after: after);
    } else {
      await commands.reorder(moved, after: after);
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    final selected = ref.watch(selectedTaskProvider);
    final select = ref.read(selectedTaskProvider.notifier).select;
    final container =
        view.section is ProjectSection || view.section is AreaSection;
    final slivers = <Widget>[];
    for (var s = 0; s < view.sections.length; s++) {
      final section = view.sections[s];
      final items = _items(s, section);
      final labelled = section.kind != TaskViewSectionKind.flat;
      if (items.isEmpty && !(labelled && container)) continue;
      if (labelled) {
        final label = section.kind == TaskViewSectionKind.day
            ? dayGroupLabel(section.day!, today: widget.today)
            : section.title;
        slivers.add(
          SliverToBoxAdapter(
            child: TaskSectionHeader(
              label: label,
              meta: _meta(section.tasks.length),
            ),
          ),
        );
      }
      final canDrag = reorderable(view, section) && items.length > 1;
      Widget row(int i) {
        final item = items[i];
        final task = item.task;
        final ghost = item.ghost;
        return TaskRow(
          key: ghost == null
              ? taskRowKey(task.id)
              : ValueKey('ghost-${task.id}'),
          task: task,
          chips: taskRowChips(
            task,
            today: widget.today,
            section: view.section,
            container: containerLabel(widget.projection, task),
            tags: tagLabels(widget.projection, task),
          ),
          selected: ghost == null && selected == task.id,
          finishing: ghost?.finish,
          entering: ghost == null && _entering.contains(task.id),
          onSelect: ghost == null ? () => select(task.id) : null,
          onCheck: ghost == null
              ? () => _finish(task, s, i, RowFinish.completed)
              : null,
          onCancel: ghost == null && task.status == TaskStatus.open
              ? () => _finish(task, s, i, RowFinish.cancelled)
              : null,
          onGone: ghost == null
              ? null
              : () => setState(() => _ghosts.remove(task.id)),
          gutter: canDrag && ghost == null
              ? (child) => ReorderableDragStartListener(index: i, child: child)
              : null,
        );
      }

      slivers.add(
        canDrag
            ? SliverReorderableList(
                itemCount: items.length,
                itemBuilder: (context, i) => row(i),
                onReorderItem: (from, to) => _reorder(section, items, from, to),
                proxyDecorator: (child, index, animation) => Material(
                  color: SaiColors.bg,
                  elevation: 6,
                  shadowColor: SaiColors.ink.withValues(alpha: 0.35),
                  child: child,
                ),
              )
            : SliverList.builder(
                itemCount: items.length,
                itemBuilder: (context, i) => row(i),
              ),
      );
    }
    slivers.add(const SliverPadding(padding: EdgeInsets.only(bottom: 80)));
    return CustomScrollView(slivers: slivers);
  }
}
