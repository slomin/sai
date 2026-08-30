import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../commands.dart';
import '../organise/heading_menu.dart';
import '../organise/organise_commands.dart';
import '../reorder/reorder.dart';
import '../widgets/empty_state.dart';
import 'dates.dart';
import 'empty_states.dart';
import 'ordering.dart';
import 'task_commands.dart';
import 'task_menu.dart';
import 'task_row.dart';
import 'task_row_chips.dart';
import 'task_section_header.dart';

export 'ordering.dart' show reorderable;

/// What names a section across rebuilds: the day, the container, the
/// heading — never its position, which shifts when a group empties.
typedef _SectionKey = (
  TaskViewSectionKind,
  CalendarDate?,
  AreaId?,
  ProjectId?,
  HeadingId?,
  String,
);

_SectionKey _keyOf(TaskViewSection s) =>
    (s.kind, s.day, s.area, s.project, s.heading, s.title);

/// A row that has just left [TaskView] but is still on screen, finishing
/// where it was.
final class _Ghost {
  _Ghost(this.task, this.section, this.at, this.index, this.finish);

  final Task task;
  final _SectionKey section;

  /// Where the section stood in the view, for a section that emptied.
  final int at;
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

/// A row's least height, the guess when no row has been measured yet.
const _rowExtent = 56.0;

class _TaskListBodyState extends ConsumerState<TaskListBody> {
  final _scroll = ScrollController();
  final _ghosts = <TaskId, _Ghost>{};

  /// One drag mechanic per section shown (#98), kept across rebuilds so
  /// a live drag survives the store's emissions — and one for a
  /// project's headings.
  final _groups = <_SectionKey, ReorderController<TaskId>>{};
  ReorderController<HeadingId>? _headings;
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
    // A ghost belongs to the view it left; another section starts clean,
    // and so do the drag groups.
    if (widget.view.section != _knownSection) {
      _ghosts.clear();
      for (final group in _groups.values) {
        group.dispose();
      }
      _groups.clear();
      _headings?.dispose();
      _headings = null;
    }
    _knownSection = widget.view.section;
    // A ghost whose task is back in the view (undo) gives way to the row.
    _ghosts.removeWhere((id, _) => ids.contains(id));
  }

  @override
  void initState() {
    super.initState();
    _known = {for (final t in widget.view.tasks) t.id};
    _knownSection = widget.view.section;
    // A selection restored at launch is already set when the list first
    // builds; nothing changes for the listener below to see.
    if (ref.read(selectedTaskProvider) case final selected?) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _seek(selected));
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    for (final group in _groups.values) {
      group.dispose();
    }
    _headings?.dispose();
    super.dispose();
  }

  /// The drag group of a project's headings (#98): a drop reorders them
  /// within the project; a task or a row from elsewhere is refused.
  ReorderController<HeadingId> _headingGroup(ProjectId project) =>
      _headings ??= ReorderController<HeadingId>(
        group: ('headings', project),
        refusal: 'a heading is ordered within its project',
        onRefused: (reason) =>
            ref.read(noticeProvider.notifier).show('reorder failed: $reason'),
        onDrop: (moved, after) => ref
            .read(organiseCommandsProvider)
            .reorderHeading(moved, after: after),
      );

  /// The drag group of the section keyed [key]: a drop is a reorder in
  /// Today's own order or a structural move, the anchor the nearest open
  /// live row above the slot; a task from another section is refused —
  /// the sheet is how a task changes group.
  ReorderController<TaskId> _group(_SectionKey key) =>
      _groups.putIfAbsent(key, () {
        return ReorderController<TaskId>(
          group: key,
          refusal:
              'a task is dragged within its group; Move / Schedule… files '
              'it elsewhere',
          onRefused: (reason) =>
              ref.read(noticeProvider.notifier).show('reorder failed: $reason'),
          onDrop: (moved, after) async {
            final commands = ref.read(taskCommandsProvider);
            if (widget.view.section == const ListSection(TaskList.today)) {
              await commands.reorderToday(moved, after: after);
            } else {
              await commands.reorder(moved, after: after);
            }
          },
        );
      });

  /// The built rows: each task's index in the view against the scroll
  /// offset that would put its row at the top. A lazy list builds only
  /// what is near the viewport, so what is here is what exists.
  Map<int, double> _builtRows() {
    final index = {
      for (final (i, task) in widget.view.tasks.indexed) task.id: i,
    };
    final out = <int, double>{};
    void visit(Element element) {
      final widget = element.widget;
      if (widget is TaskRow) {
        final at = index[widget.task.id];
        final box = element.renderObject;
        if (at != null &&
            widget.key == taskRowKey(widget.task.id) &&
            box is RenderBox &&
            box.hasSize) {
          out[at] = RenderAbstractViewport.of(box)
              .getOffsetToReveal(box, 0)
              .offset;
        }
        return;
      }
      element.visitChildElements(visit);
    }

    context.visitChildElements(visit);
    return out;
  }

  /// Brings the list to [id]'s row when the row does not exist yet: from
  /// the nearest built row, as many rows away as the view says, at the
  /// height the built rows measure — then looks again next frame, since
  /// rows and headers are not all one height, until the row is there and
  /// shows itself. A built row needs nothing from here.
  void _seek(TaskId id, [int attempt = 0]) {
    if (!mounted || !_scroll.hasClients || attempt > 8) return;
    final target = widget.view.tasks.indexWhere((t) => t.id == id);
    if (target < 0) return;
    final built = _builtRows();
    if (built.isEmpty || built.containsKey(target)) return;
    final indices = built.keys.toList()..sort();
    final nearest = indices.reduce(
      (a, b) => (a - target).abs() <= (b - target).abs() ? a : b,
    );
    final first = indices.first;
    final last = indices.last;
    final extent = last > first
        ? (built[last]! - built[first]!) / (last - first)
        : _rowExtent;
    final position = _scroll.position;
    final estimate =
        built[nearest]! +
        (target - nearest) * extent -
        position.viewportDimension / 2;
    position.jumpTo(estimate.clamp(0.0, position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) => _seek(id, attempt + 1));
  }

  Future<void> _finish(
    Task task,
    _SectionKey section,
    int at,
    int index,
    RowFinish finish,
  ) async {
    final commands = ref.read(taskCommandsProvider);
    if (task.status != TaskStatus.open) {
      // The check on a finished row — in the Logbook, or a row kept in
      // its list until midnight (#97) — reopens: the row simply leaves
      // the Logbook, or takes its colour back where it stands.
      await commands.reopen(task.id);
      return;
    }
    final retained =
        ref.read(finishedTaskVisibilityProvider) ==
        FinishedTaskVisibility.endOfDay;
    if (retained) {
      // End of day (#97): the store answers, the view keeps the row at
      // its position and it re-renders finished — the mark fills, the
      // title greys; nothing collapses until midnight.
      if (finish == RowFinish.completed) {
        await commands.complete(task.id);
      } else {
        await commands.cancel(task.id);
      }
      return;
    }
    setState(() => _ghosts[task.id] = _Ghost(task, section, at, index, finish));
    final ok = finish == RowFinish.completed
        ? await commands.complete(task.id)
        : await commands.cancel(task.id);
    if (!ok && mounted) setState(() => _ghosts.remove(task.id));
  }

  List<_Item> _items(_SectionKey key, TaskViewSection section) {
    final items = [for (final t in section.tasks) _Item(t)];
    final ghosts = _ghosts.values.where((g) => g.section == key).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    for (final ghost in ghosts) {
      final at = ghost.index.clamp(0, items.length);
      items.insert(at, _Item(ghost.task, ghost: ghost));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.view;
    final selected = ref.watch(selectedTaskProvider);
    final select = ref.read(selectedTaskProvider.notifier).select;
    ref.listen(selectedTaskProvider, (_, next) {
      if (next == null) return;
      // After the frame: a selection that came with a new section (Quick
      // Find) is judged against that section's list, not the old one.
      WidgetsBinding.instance.addPostFrameCallback((_) => _seek(next));
    });
    final container =
        view.section is ProjectSection || view.section is AreaSection;
    // A day that just emptied is gone from the view; its ghost still
    // finishes under that day, so the sections rendered are the view's
    // plus any a ghost still needs.
    final sections = [...view.sections];
    for (final ghost in _ghosts.values) {
      if (sections.any((s) => _keyOf(s) == ghost.section)) continue;
      sections.insert(
        ghost.at.clamp(0, sections.length),
        TaskViewSection(
          kind: ghost.section.$1,
          title: ghost.section.$6,
          day: ghost.section.$2,
          area: ghost.section.$3,
          project: ghost.section.$4,
          heading: ghost.section.$5,
          tasks: const [],
        ),
      );
    }
    // A container with headings shows them even when nothing is in them.
    if (view.tasks.isEmpty &&
        _ghosts.isEmpty &&
        !(container && sections.length > 1)) {
      return _Empty(section: view.section, title: view.title);
    }
    final slivers = <Widget>[];
    for (var at = 0; at < sections.length; at++) {
      final section = sections[at];
      final s = _keyOf(section);
      final items = _items(s, section);
      final labelled = section.kind != TaskViewSectionKind.flat;
      if (items.isEmpty && !(labelled && container)) continue;
      if (labelled) {
        final label = section.kind == TaskViewSectionKind.day
            ? dayGroupLabel(section.day!, today: widget.today)
            : section.title;
        final ownHeading =
            section.kind == TaskViewSectionKind.heading &&
            view.section is ProjectSection;
        Widget header(Widget? handle) => TaskSectionHeader(
          label: label,
          meta: _meta(section.tasks.length),
          leading: handle,
          trailing: ownHeading
              ? HeadingMenu(heading: section.heading!, title: section.title)
              : null,
        );
        if (ownHeading) {
          final project = (view.section as ProjectSection).project;
          final headings = [
            for (final h in widget.projection.headingsOf(project)) h.id,
          ];
          final group = _headingGroup(project)..order = headings;
          slivers.add(
            SliverToBoxAdapter(
              child: ReorderRow<HeadingId>(
                key: ValueKey('reorder-heading-${section.heading}'),
                controller: group,
                id: section.heading!,
                title: section.title,
                enabled: headings.length > 1,
                builder: (context, handle) => header(handle),
              ),
            ),
          );
        } else {
          slivers.add(SliverToBoxAdapter(child: header(null)));
        }
      }
      final canDrag = reorderable(view, section) && items.length > 1;
      ReorderController<TaskId>? group;
      if (canDrag) {
        group = _group(s)
          ..order = [for (final item in items) item.task.id]
          ..canAnchor = (id) =>
              !_ghosts.containsKey(id) &&
              widget.projection.task(id)?.status == TaskStatus.open;
      }
      // A row in the Trash is selectable and nothing else (#97): Restore
      // is the inspector's, and a deleted task keeps its status.
      final trash = view.section == const TrashSection();
      Widget row(int i) {
        final item = items[i];
        final task = item.task;
        final ghost = item.ghost;
        // A live row outside the Trash carries its menu (#98).
        if (ghost == null && !trash) {
          Widget live(BuildContext context, Widget? handle) => TaskMenu(
            key: ValueKey('menu-${task.id}'),
            task: task,
            view: view,
            builder: (context, open, button) => TaskRow(
              key: taskRowKey(task.id),
              task: task,
              chips: taskRowChips(
                task,
                today: widget.today,
                section: view.section,
                container: containerLabel(widget.projection, task),
                tags: tagLabels(widget.projection, task),
              ),
              selected: selected == task.id,
              entering: _entering.contains(task.id),
              onSelect: () => select(task.id),
              onCheck: () => _finish(task, s, at, i, RowFinish.completed),
              onCancel: task.status == TaskStatus.open
                  ? () => _finish(task, s, at, i, RowFinish.cancelled)
                  : null,
              handle: handle,
              trailing: button,
              onSecondaryTapDown: (at) => open(at),
            ),
          );
          if (group == null) return live(context, null);
          // A finished row kept until midnight (#97) is a target — the
          // slot beside it works — but is not itself dragged: the store
          // refuses a finished anchor, so it stays where it is.
          return ReorderRow<TaskId>(
            key: ValueKey('reorder-${task.id}'),
            controller: group,
            id: task.id,
            title: task.title,
            enabled: task.status == TaskStatus.open,
            builder: live,
          );
        }
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
          onCheck: ghost == null && !trash
              ? () => _finish(task, s, at, i, RowFinish.completed)
              : null,
          onCancel: ghost == null && !trash && task.status == TaskStatus.open
              ? () => _finish(task, s, at, i, RowFinish.cancelled)
              : null,
          onGone: ghost == null
              ? null
              // Reported after the frame that dropped the row, which may
              // also be the one that dropped this body.
              : () {
                  if (mounted) setState(() => _ghosts.remove(task.id));
                },
        );
      }

      slivers.add(
        SliverList.builder(
          itemCount: items.length,
          itemBuilder: (context, i) => row(i),
        ),
      );
    }
    slivers.add(const SliverPadding(padding: EdgeInsets.only(bottom: 80)));
    // Keyed by section, so each list opens at its top rather than at
    // wherever the previous one was scrolled to.
    return CustomScrollView(
      key: ValueKey(('list', view.section)),
      controller: _scroll,
      slivers: slivers,
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.section, required this.title});

  final SidebarSection section;
  final String title;

  @override
  Widget build(BuildContext context) {
    final copy = emptyCopy(section, title);
    // Scrolls rather than overflows when the window is short.
    return SingleChildScrollView(
      child: Align(
        alignment: Alignment.topLeft,
        child: EmptyState(
          eyebrow: copy.eyebrow,
          title: copy.title,
          body: copy.body,
        ),
      ),
    );
  }
}
