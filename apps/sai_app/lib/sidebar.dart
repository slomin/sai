import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

/// The standard lists, the Trash, then areas with their projects nested
/// and the standalone projects — the shape [sidebarModel] hands every
/// client. Tapping a row selects its section.
class SaiSidebar extends ConsumerWidget {
  const SaiSidebar({super.key, required this.projection});

  final TaskProjection projection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final model = sidebarModel(projection, today: ref.watch(todayProvider));
    final selected = ref.watch(selectedSectionProvider);
    final select = ref.read(selectedSectionProvider.notifier).select;
    Widget row(SidebarEntry entry, {int indent = 0}) => _Row(
      entry,
      selected: entry.section == selected,
      indent: indent,
      onTap: () => select(entry.section),
    );
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final entry in model.lists) row(entry),
        row(model.trash),
        if (model.areas.isNotEmpty || model.projects.isNotEmpty)
          const Divider(height: 17),
        for (final area in model.areas) ...[
          row(area.entry),
          for (final project in area.projects) row(project, indent: 1),
        ],
        for (final project in model.projects) row(project),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(
    this.entry, {
    required this.selected,
    required this.indent,
    required this.onTap,
  });

  final SidebarEntry entry;
  final bool selected;
  final int indent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? scheme.secondaryContainer : null,
        padding: EdgeInsets.only(
          left: 12.0 + 16.0 * indent,
          right: 12,
          top: 6,
          bottom: 6,
        ),
        child: Text(
          entry.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: selected
              ? TextStyle(color: scheme.onSecondaryContainer)
              : null,
        ),
      ),
    );
  }
}
