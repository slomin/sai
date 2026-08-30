import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../widgets/glyph_button.dart';
import '../widgets/sai_dialog.dart';
import 'move_sheet.dart';
import 'ordering.dart';
import 'task_commands.dart';

/// The "…" button of a task's row, for tests; the menu's items are found
/// by their labels.
Key taskMenuKey(TaskId task) => ValueKey(('task-menu', task));

/// Asks before a task goes to the Trash; true when confirmed.
Future<bool> confirmDeleteTask(BuildContext context, Task task) async {
  final answer = await confirmAction(
    context,
    eyebrow: 'Task',
    title: 'Delete “${task.title}”?',
    body: 'It moves to the Trash; the archive keeps its history.',
    confirm: 'Delete',
  );
  return answer.confirmed;
}

/// The menu of a task's row (#98): Move / Schedule…, Move up and Move
/// down where the list can be reordered, Complete or Reopen, Cancel
/// while open, Delete…. Opens from the row's "…" button — always in the
/// tree for the keyboard and assistive tech, shown on hover and
/// selection like the cross — and from a secondary click anywhere on
/// the row; opening selects the row, so the inspector shows what the
/// menu is about.
class TaskMenu extends ConsumerStatefulWidget {
  const TaskMenu({
    super.key,
    required this.task,
    required this.view,
    required this.builder,
  });

  final Task task;
  final TaskView view;

  /// Builds the row; [open] shows the menu at [at] (row-local), or under
  /// the "…" button when null.
  final Widget Function(
    BuildContext context,
    void Function([Offset? at]) open,
    Widget button,
  )
  builder;

  @override
  ConsumerState<TaskMenu> createState() => _TaskMenuState();
}

class _TaskMenuState extends ConsumerState<TaskMenu> {
  final _controller = MenuController();

  void _open([Offset? at]) {
    if (_controller.isOpen) {
      _controller.close();
      return;
    }
    ref.read(selectedTaskProvider.notifier).select(widget.task.id);
    _controller.open(position: at);
  }

  Future<void> _delete() async {
    final commands = ref.read(taskCommandsProvider);
    if (!await confirmDeleteTask(context, widget.task)) return;
    await commands.delete(widget.task.id);
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final open = task.status == TaskStatus.open;
    final section = widget.view.sections
        .where((s) => s.tasks.any((t) => t.id == task.id))
        .firstOrNull;
    final ordered =
        open && section != null && reorderable(widget.view, section);
    final commands = ref.read(taskCommandsProvider);
    final button = GlyphButton(
      key: taskMenuKey(task.id),
      glyph: '…',
      label: 'Options for ${task.title}',
      onPressed: () => _open(),
    );
    return MenuAnchor(
      controller: _controller,
      menuChildren: [
        MenuItemButton(
          onPressed: () => showMoveSheet(context, task.id),
          child: const Text('Move / Schedule…'),
        ),
        if (ordered) ...[
          MenuItemButton(
            onPressed: () => commands.nudge(task.id, -1, view: widget.view),
            child: const Text('Move up'),
          ),
          MenuItemButton(
            onPressed: () => commands.nudge(task.id, 1, view: widget.view),
            child: const Text('Move down'),
          ),
        ],
        MenuItemButton(
          onPressed: () =>
              open ? commands.complete(task.id) : commands.reopen(task.id),
          child: Text(open ? 'Complete' : 'Reopen'),
        ),
        if (open)
          MenuItemButton(
            onPressed: () => commands.cancel(task.id),
            child: const Text('Cancel'),
          ),
        MenuItemButton(onPressed: _delete, child: const Text('Delete…')),
      ],
      child: widget.builder(context, _open, button),
    );
  }
}
