import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

/// Where the selected task stands in its view, or null while nothing is
/// selected or the selection has left the view.
final selectionIndexProvider = Provider<int?>((ref) {
  final selected = ref.watch(selectedTaskProvider);
  if (selected == null) return null;
  final section = ref.watch(selectedSectionProvider);
  final tasks = ref.watch(taskViewProvider(section)).value?.tasks;
  if (tasks == null) return null;
  final at = tasks.indexWhere((t) => t.id == selected);
  return at < 0 ? null : at;
});

/// The arrow keys in the workspace (#89). Which pane they move is read
/// off the screen rather than kept: a selected task means the list, none
/// means the sidebar. Its state is the last place the selection stood in
/// its view, so a task that has left the list — completed from Today —
/// is stepped from where it was.
final workspaceNavigatorProvider = NotifierProvider<WorkspaceNavigator, int?>(
  WorkspaceNavigator.new,
);

class WorkspaceNavigator extends Notifier<int?> {
  @override
  int? build() {
    ref.listen(selectionIndexProvider, (_, next) {
      if (next != null) state = next;
    });
    return ref.read(selectionIndexProvider);
  }

  void move(NavDirection direction) {
    final section = ref.read(selectedSectionProvider);
    final tasks =
        ref.read(taskViewProvider(section)).value?.tasks ?? const <Task>[];
    final selected = ref.read(selectedTaskProvider);
    if (selected != null) {
      _moveInList(tasks, selected, direction);
    } else {
      _moveInSidebar(section, tasks, direction);
    }
  }

  void _moveInList(List<Task> tasks, TaskId selected, NavDirection direction) {
    final selection = ref.read(selectedTaskProvider.notifier);
    switch (direction) {
      case NavDirection.up || NavDirection.down:
        final next = stepTask(tasks, selected, direction, lastIndex: state);
        if (next != null) selection.select(next);
      case NavDirection.left:
        // Back to the sidebar row, which is where it was all along.
        selection.clear();
      case NavDirection.right:
        break;
    }
  }

  void _moveInSidebar(
    SidebarSection section,
    List<Task> tasks,
    NavDirection direction,
  ) {
    final collapsed = ref.read(collapsedAreasProvider);
    final fold = ref.read(collapsedAreasProvider.notifier);
    final area = section is AreaSection ? section.area : null;
    switch (direction) {
      case NavDirection.up || NavDirection.down:
        final model = ref.read(sidebarProvider).value;
        if (model == null) return;
        final rows = visibleSidebarRows(model, collapsed);
        final next = stepSection(rows, section, direction);
        if (next != null) {
          ref.read(selectedSectionProvider.notifier).select(next);
        }
      case NavDirection.right:
        if (area != null && collapsed.contains(area)) {
          fold.toggle(area);
          return;
        }
        final first = stepTask(tasks, null, direction);
        if (first != null) {
          ref.read(selectedTaskProvider.notifier).select(first);
        }
      case NavDirection.left:
        if (area != null && !collapsed.contains(area)) fold.toggle(area);
    }
  }
}
