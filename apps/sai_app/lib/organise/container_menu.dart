import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../theme/sai_tokens.dart';
import '../widgets/sai_dialog.dart';
import 'organise_commands.dart';
import '../widgets/glyph_button.dart';

/// The "…" button of a container's sidebar row, for tests; the menu's
/// items are found by their labels.
Key containerMenuKey(SidebarSection section) =>
    ValueKey(('container-menu', section));

/// The organisation menu of an area or project (#74): rename, a new
/// project (area) or heading (project), move up or down in the persisted
/// order, archive or unarchive, delete. Opens from the row's "…" button
/// — always present for the keyboard and assistive tech — and from a
/// secondary click anywhere on the row.
class ContainerMenu extends ConsumerStatefulWidget {
  const ContainerMenu({
    super.key,
    required this.section,
    required this.title,
    required this.archived,
    required this.builder,
  });

  final SidebarSection section;
  final String title;
  final bool archived;

  /// Builds the row; [open] shows the menu at [at] (row-local), or under
  /// the "…" button when null.
  final Widget Function(
    BuildContext context,
    void Function([Offset? at]) open,
    Widget button,
  )
  builder;

  @override
  ConsumerState<ContainerMenu> createState() => _ContainerMenuState();
}

class _ContainerMenuState extends ConsumerState<ContainerMenu> {
  final _controller = MenuController();

  void _open([Offset? at]) {
    if (_controller.isOpen) {
      _controller.close();
      return;
    }
    _controller.open(position: at);
  }

  /// Moves the shell off a container that is about to go: to the
  /// project's area, else Today.
  void _leave() {
    final section = widget.section;
    if (ref.read(selectedSectionProvider) != section) return;
    final projection = ref.read(tasksProvider).value;
    final area = switch (section) {
      ProjectSection(:final project) => projection?.projects[project]?.area,
      _ => null,
    };
    final live =
        area != null &&
        projection?.areas[area]?.deletedAt == null &&
        projection?.areas[area]?.archivedAt == null;
    ref
        .read(selectedSectionProvider.notifier)
        .select(live ? AreaSection(area) : const ListSection(TaskList.today));
  }

  Future<void> _rename() async {
    final kind = widget.section is AreaSection ? 'Area' : 'Project';
    final title = await promptForTitle(
      context,
      eyebrow: kind,
      title: 'Rename “${widget.title}”',
      initial: widget.title,
      confirm: 'Rename',
    );
    if (title == null || title == widget.title) return;
    final organise = ref.read(organiseCommandsProvider);
    switch (widget.section) {
      case AreaSection(:final area):
        await organise.renameArea(area, title);
      case ProjectSection(:final project):
        await organise.renameProject(project, title);
      case _:
        break;
    }
  }

  Future<void> _newChild() async {
    // Read before the prompt: this row leaves the tree when its container
    // goes underneath, and a ref read after the await would throw.
    final organise = ref.read(organiseCommandsProvider);
    final select = ref.read(selectedSectionProvider.notifier).select;
    switch (widget.section) {
      case AreaSection(:final area):
        final title = await promptForTitle(
          context,
          eyebrow: widget.title,
          title: 'New project',
          confirm: 'Create',
        );
        if (title == null) return;
        final id = await organise.createProject(title, area: area);
        if (id != null) select(ProjectSection(id));
      case ProjectSection(:final project):
        // Committed while the prompt is up (#96), then the project is
        // shown: a heading made from another list was invisible before.
        final title = await promptForTitle(
          context,
          eyebrow: widget.title,
          title: 'New heading',
          confirm: 'Create',
          commit: (title) => organise.tryCreateHeading(project, title),
        );
        if (title == null) return;
        select(ProjectSection(project));
      case _:
        break;
    }
  }

  Future<bool> _nudge(int by) {
    final organise = ref.read(organiseCommandsProvider);
    return switch (widget.section) {
      AreaSection(:final area) => organise.nudgeArea(area, by),
      ProjectSection(:final project) => organise.nudgeProject(project, by),
      _ => Future.value(false),
    };
  }

  Future<void> _archive() async {
    final organise = ref.read(organiseCommandsProvider);
    if (!widget.archived) _leave();
    switch (widget.section) {
      case AreaSection(:final area):
        await (widget.archived
            ? organise.unarchiveArea(area)
            : organise.archiveArea(area));
      case ProjectSection(:final project):
        await (widget.archived
            ? organise.unarchiveProject(project)
            : organise.archiveProject(project));
      case _:
        break;
    }
  }

  Future<void> _delete() async {
    final organise = ref.read(organiseCommandsProvider);
    final count = organise.taskCount(widget.section);
    final kind = widget.section is AreaSection ? 'Area' : 'Project';
    final answer = await confirmAction(
      context,
      eyebrow: kind,
      title: 'Delete “${widget.title}”?',
      body: count == 0
          ? 'It holds no open task. The archive keeps its history.'
          : widget.section is AreaSection
          ? 'Its projects stay, listed on their own. The archive keeps '
                'its history.'
          : 'The archive keeps its history.',
      confirm: 'Delete',
      option: count == 0
          ? null
          : 'Move its $count open task${count == 1 ? '' : 's'} to the Inbox first',
    );
    if (!answer.confirmed) return;
    _leave();
    switch (widget.section) {
      case AreaSection(:final area):
        await organise.deleteArea(area, moveTasks: answer.option);
      case ProjectSection(:final project):
        await organise.deleteProject(project, moveTasks: answer.option);
      case _:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isArea = widget.section is AreaSection;
    final button = GlyphButton(
      key: containerMenuKey(widget.section),
      glyph: '…',
      label: 'Options for ${widget.title}',
      onPressed: () => _open(),
    );
    return MenuAnchor(
      controller: _controller,
      menuChildren: [
        MenuItemButton(onPressed: _rename, child: const Text('Rename…')),
        if (!widget.archived) ...[
          MenuItemButton(
            onPressed: _newChild,
            child: Text(isArea ? 'New project…' : 'New heading…'),
          ),
          MenuItemButton(
            onPressed: () => _nudge(-1),
            child: const Text('Move up'),
          ),
          MenuItemButton(
            onPressed: () => _nudge(1),
            child: const Text('Move down'),
          ),
        ],
        MenuItemButton(
          onPressed: _archive,
          child: Text(widget.archived ? 'Unarchive' : 'Archive'),
        ),
        MenuItemButton(onPressed: _delete, child: const Text('Delete…')),
      ],
      child: widget.builder(context, _open, button),
    );
  }
}

/// The "+" beside the AREAS & PROJECTS heading, for tests.
const sidebarAddKey = Key('sidebar-add');

/// New area, new project — the sidebar's own additions.
class SidebarAddMenu extends ConsumerWidget {
  const SidebarAddMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final organise = ref.read(organiseCommandsProvider);
    Future<void> newArea() async {
      final title = await promptForTitle(
        context,
        eyebrow: 'Area',
        title: 'New area',
        confirm: 'Create',
      );
      if (title == null) return;
      final id = await organise.createArea(title);
      if (id != null) {
        ref.read(selectedSectionProvider.notifier).select(AreaSection(id));
      }
    }

    Future<void> newProject() async {
      final title = await promptForTitle(
        context,
        eyebrow: 'Project',
        title: 'New project',
        confirm: 'Create',
      );
      if (title == null) return;
      final id = await organise.createProject(title);
      if (id != null) {
        ref.read(selectedSectionProvider.notifier).select(ProjectSection(id));
      }
    }

    return MenuAnchor(
      menuChildren: [
        MenuItemButton(onPressed: newArea, child: const Text('New area…')),
        MenuItemButton(
          onPressed: newProject,
          child: const Text('New project…'),
        ),
      ],
      builder: (context, controller, _) => GlyphButton(
        key: sidebarAddKey,
        glyph: '+',
        label: 'New area or project',
        color: SaiColors.inkFaint,
        minSize: 20,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
