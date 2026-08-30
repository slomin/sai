import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'commands.dart';
import 'organise/container_menu.dart';
import 'organise/organise_commands.dart';
import 'reorder/reorder.dart';
import 'theme/sai_theme.dart';
import 'theme/sai_tokens.dart';
import 'widgets/eyebrow.dart';
import 'widgets/glyph_button.dart';
import 'workspace/task_row.dart' show revealRow;

/// The key of a section's row, for tests: sections are value types.
Key sidebarRowKey(SidebarSection section) => ValueKey(section);

/// The key of an area's fold chevron (#76), for tests.
Key sidebarChevronKey(AreaId area) => ValueKey(('chevron', area));

/// The standard lists with their counts, the Trash, then areas with their
/// projects nested and the standalone projects in their persisted order,
/// then the archived containers — [sidebarProvider]'s shape. Tapping a
/// row selects its section; a container row's "…" (or a secondary
/// click) opens its organisation menu (#74).
class SaiSidebar extends ConsumerStatefulWidget {
  const SaiSidebar({super.key});

  @override
  ConsumerState<SaiSidebar> createState() => _SaiSidebarState();
}

/// The sidebar's fixed geometry, for the jump below: the list's top
/// padding, a group heading with its gap, a row, the space between groups.
const _topPadding = 22.0;
const _headingExtent = 30.0;
const _rowExtent = 38.0;
const _groupGap = 26.0;

class _SaiSidebarState extends ConsumerState<SaiSidebar> {
  final _scroll = ScrollController();

  /// The drag groups (#98): the live areas, and the projects of each
  /// group — an area's, or the standalone ones (keyed null).
  ReorderController<AreaId>? _areas;
  final _projects = <AreaId?, ReorderController<ProjectId>>{};

  void _refused(String reason) =>
      ref.read(noticeProvider.notifier).show('reorder failed: $reason');

  ReorderController<AreaId> _areaGroup() =>
      _areas ??= ReorderController<AreaId>(
        group: 'areas',
        refusal: 'only an area is ordered among the areas',
        onRefused: _refused,
        onDrop: (moved, after) =>
            ref.read(organiseCommandsProvider).reorderArea(moved, after: after),
      );

  ReorderController<ProjectId> _projectGroup(AreaId? area) =>
      _projects.putIfAbsent(
        area,
        () => ReorderController<ProjectId>(
          group: ('projects', area),
          refusal: area == null
              ? 'a project is ordered among the standalone projects'
              : 'a project is ordered within its area',
          onRefused: _refused,
          onDrop: (moved, after) => ref
              .read(organiseCommandsProvider)
              .reorderProject(moved, after: after),
        ),
      );

  /// Where each row's top sits in the scroll, as of the last build.
  var _offsets = <SidebarSection, double>{};

  @override
  void initState() {
    super.initState();
    // A section restored at launch is set before the first build.
    final restored = ref.read(selectedSectionProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) => _seek(restored));
  }

  @override
  void dispose() {
    _scroll.dispose();
    _areas?.dispose();
    for (final group in _projects.values) {
      group.dispose();
    }
    super.dispose();
  }

  bool _built(SidebarSection section) {
    final key = sidebarRowKey(section);
    var found = false;
    void visit(Element element) {
      if (found) return;
      if (element.widget.key == key) {
        found = true;
        return;
      }
      element.visitChildElements(visit);
    }

    context.visitChildElements(visit);
    return found;
  }

  /// Brings the list to [section]'s row when the list has not built it —
  /// the rows are one height, so the offset is known exactly; a built row
  /// shows itself (#89).
  void _seek(SidebarSection section) {
    if (!mounted || !_scroll.hasClients || _built(section)) return;
    final offset = _offsets[section];
    if (offset == null) return;
    final position = _scroll.position;
    position.jumpTo(
      (offset - position.viewportDimension / 2).clamp(
        0.0,
        position.maxScrollExtent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(selectedSectionProvider, (_, next) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _seek(next));
    });
    final model = ref.watch(sidebarProvider).value;
    final selected = ref.watch(selectedSectionProvider);
    final select = ref.read(selectedSectionProvider.notifier).select;
    final collapsed = ref.watch(collapsedAreasProvider);
    final fold = ref.read(collapsedAreasProvider.notifier).toggle;
    if (model == null) return const SizedBox.shrink();
    Widget row(SidebarEntry entry, {bool count = true, bool nested = false}) =>
        SidebarRow(
          key: sidebarRowKey(entry.section),
          title: nested ? '— ${entry.title}' : entry.title,
          count: count ? entry.count : null,
          selected: entry.section == selected,
          onTap: () => select(entry.section),
        );
    Widget container(
      SidebarEntry entry, {
      bool nested = false,
      bool archived = false,
      Widget? leading,
      Widget? handle,
    }) => ContainerMenu(
      section: entry.section,
      title: entry.title,
      archived: archived,
      builder: (context, open, button) => SidebarRow(
        key: sidebarRowKey(entry.section),
        title: nested ? '— ${entry.title}' : entry.title,
        count: null,
        selected: entry.section == selected,
        dim: archived,
        leading: leading,
        handle: handle,
        trailing: button,
        onTap: () => select(entry.section),
        onSecondaryTapDown: (at) => open(at),
      ),
    );
    // A live area or project row is a drag target of its group and, with
    // a sibling to change places with, carries the handle (#98).
    final areaIds = [
      for (final area in model.areas) (area.entry.section as AreaSection).area,
    ];
    final areas = _areaGroup()..order = areaIds;
    Widget areaRow(SidebarArea area, {required Widget chevron}) =>
        ReorderRow<AreaId>(
          key: ValueKey(('reorder', area.entry.section)),
          controller: areas,
          id: (area.entry.section as AreaSection).area,
          title: area.entry.title,
          enabled: areaIds.length > 1,
          builder: (context, handle) =>
              container(area.entry, leading: chevron, handle: handle),
        );
    Widget projectRow(SidebarEntry entry, {AreaId? area, bool nested = false}) {
      final siblings = [
        for (final p
            in area == null
                ? model.projects
                : model.areas
                      .firstWhere(
                        (a) => (a.entry.section as AreaSection).area == area,
                      )
                      .projects)
          (p.section as ProjectSection).project,
      ];
      final group = _projectGroup(area)..order = siblings;
      return ReorderRow<ProjectId>(
        key: ValueKey(('reorder', entry.section)),
        controller: group,
        id: (entry.section as ProjectSection).project,
        title: entry.title,
        enabled: siblings.length > 1,
        builder: (context, handle) =>
            container(entry, nested: nested, handle: handle),
      );
    }

    // The fold chevron (#76): folded areas keep their projects out of the
    // sidebar; the set is remembered across launches.
    Widget chevron(SidebarArea area, {required bool folded}) {
      final id = (area.entry.section as AreaSection).area;
      return GlyphButton(
        key: sidebarChevronKey(id),
        glyph: folded ? '›' : '⌄',
        label: folded
            ? 'Expand ${area.entry.title}'
            : 'Collapse ${area.entry.title}',
        size: 13,
        minSize: 20,
        onPressed: () => fold(id),
      );
    }

    // The offsets follow the children below, item for item.
    var y = _topPadding;
    final offsets = <SidebarSection, double>{};
    void heading() => y += _headingExtent;
    void gap() => y += _groupGap;
    void at(SidebarEntry entry) {
      offsets[entry.section] = y;
      y += _rowExtent;
    }

    heading();
    model.lists.forEach(at);
    at(model.trash);
    gap();
    heading();
    for (final area in model.areas) {
      at(area.entry);
      if (!collapsed.contains((area.entry.section as AreaSection).area)) {
        area.projects.forEach(at);
      }
    }
    model.projects.forEach(at);
    if (model.archived.isNotEmpty) {
      gap();
      heading();
      model.archived.forEach(at);
    }
    _offsets = offsets;
    return Container(
      color: SaiColors.bg,
      child: ListView(
        controller: _scroll,
        padding: const EdgeInsets.only(top: _topPadding, bottom: 24),
        children: [
          const _Heading('Lists'),
          for (final entry in model.lists) row(entry),
          row(model.trash),
          const SizedBox(height: 26),
          const _Heading('Areas & projects', trailing: SidebarAddMenu()),
          for (final area in model.areas) ...[
            if (collapsed.contains((area.entry.section as AreaSection).area))
              areaRow(area, chevron: chevron(area, folded: true))
            else ...[
              areaRow(area, chevron: chevron(area, folded: false)),
              for (final project in area.projects)
                projectRow(
                  project,
                  area: (area.entry.section as AreaSection).area,
                  nested: true,
                ),
            ],
          ],
          for (final project in model.projects) projectRow(project),
          if (model.archived.isNotEmpty) ...[
            const SizedBox(height: 26),
            const _Heading('Archived'),
            for (final entry in model.archived)
              container(entry, archived: true),
          ],
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 16, 10),
      child: SizedBox(
        height: 20,
        child: Row(
          children: [
            Expanded(child: Eyebrow(text, dim: true)),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// One sidebar row: the title, the count in mono on the right, and the
/// ink treatment with a red bar when selected. A container row carries
/// its "…" button as [trailing], outside the row's own semantics.
class SidebarRow extends StatefulWidget {
  const SidebarRow({
    super.key,
    required this.title,
    required this.count,
    required this.selected,
    required this.onTap,
    this.leading,
    this.handle,
    this.trailing,
    this.onSecondaryTapDown,
    this.dim = false,
  });

  final String title;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  /// Sits in the row's left margin, outside its semantics — the area
  /// chevron. Always shown, unlike [trailing].
  final Widget? leading;

  /// The drag handle (#98), beside the "…" button, shown the same way.
  final Widget? handle;
  final Widget? trailing;
  final void Function(Offset at)? onSecondaryTapDown;
  final bool dim;

  @override
  State<SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<SidebarRow> {
  var _hovered = false;

  @override
  void initState() {
    super.initState();
    if (widget.selected) _reveal();
  }

  @override
  void didUpdateWidget(SidebarRow old) {
    super.didUpdateWidget(old);
    if (widget.selected && !old.selected) _reveal();
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) revealRow(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    final title = widget.title;
    final count = widget.count;
    final selected = widget.selected;
    final dim = widget.dim;
    final leading = widget.leading;
    final handle = widget.handle;
    final trailing = widget.trailing;
    final onSecondaryTapDown = widget.onSecondaryTapDown;
    final color = selected
        ? SaiColors.onInk
        : dim
        ? SaiColors.inkFaint
        : SaiColors.ink;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        height: 38,
        decoration: BoxDecoration(
          color: selected ? SaiColors.ink : null,
          border: Border(
            left: BorderSide(
              color: selected ? SaiColors.red : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(
          children: [
            if (leading case final leading?)
              SizedBox(
                width: 21,
                child: IconTheme(
                  data: IconThemeData(
                    color: selected ? SaiColors.onInk : SaiColors.inkFaint,
                  ),
                  child: Center(child: leading),
                ),
              ),
            Expanded(
              child: Semantics(
                button: true,
                selected: selected,
                label: count == null ? title : '$title, $count',
                child: GestureDetector(
                  onSecondaryTapDown: onSecondaryTapDown == null
                      ? null
                      : (d) => onSecondaryTapDown(d.localPosition),
                  child: InkWell(
                    onTap: widget.onTap,
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: leading == null ? 21 : 0,
                        right: trailing == null ? 24 : 4,
                      ),
                      // The row's own label carries title and count.
                      child: ExcludeSemantics(
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                style: text.sidebar.copyWith(color: color),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (count case final count?)
                              Text(
                                '$count',
                                style: text.meta.copyWith(
                                  color: selected
                                      ? SaiColors.onInk
                                      : SaiColors.inkFaint,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (handle case final handle?)
              Opacity(
                opacity: _hovered || selected ? 1 : 0,
                alwaysIncludeSemantics: true,
                child: IconTheme(
                  data: IconThemeData(
                    color: selected ? SaiColors.onInk : SaiColors.inkFaint,
                  ),
                  child: handle,
                ),
              ),
            if (trailing case final trailing?)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                // Shown on hover or selection; always in the tree, so the
                // keyboard and assistive tech reach it regardless.
                child: Opacity(
                  opacity: _hovered || selected ? 1 : 0,
                  alwaysIncludeSemantics: true,
                  child: IconTheme(
                    data: IconThemeData(
                      color: selected ? SaiColors.onInk : SaiColors.inkFaint,
                    ),
                    child: trailing,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
