import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'theme/sai_theme.dart';
import 'theme/sai_tokens.dart';
import 'widgets/eyebrow.dart';

/// The key of a section's row, for tests: sections are value types.
Key sidebarRowKey(SidebarSection section) => ValueKey(section);

/// The standard lists with their counts, the Trash, then areas with their
/// projects nested and the standalone projects — [sidebarProvider]'s
/// shape. Tapping a row selects its section.
class SaiSidebar extends ConsumerWidget {
  const SaiSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final model = ref.watch(sidebarProvider).value;
    final selected = ref.watch(selectedSectionProvider);
    final select = ref.read(selectedSectionProvider.notifier).select;
    if (model == null) return const SizedBox.shrink();
    Widget row(SidebarEntry entry, {bool count = true, bool nested = false}) =>
        SidebarRow(
          key: sidebarRowKey(entry.section),
          title: nested ? '— ${entry.title}' : entry.title,
          count: count ? entry.count : null,
          selected: entry.section == selected,
          onTap: () => select(entry.section),
        );
    return Container(
      color: SaiColors.bg,
      child: ListView(
        padding: const EdgeInsets.only(top: 22, bottom: 24),
        children: [
          const _Heading('Lists'),
          for (final entry in model.lists) row(entry),
          row(model.trash),
          if (model.areas.isNotEmpty || model.projects.isNotEmpty) ...[
            const SizedBox(height: 26),
            const _Heading('Areas & projects'),
            for (final area in model.areas) ...[
              row(area.entry, count: false),
              for (final project in area.projects)
                row(project, count: false, nested: true),
            ],
            for (final project in model.projects) row(project, count: false),
          ],
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
      child: Eyebrow(text, dim: true),
    );
  }
}

/// One sidebar row: the title, the count in mono on the right, and the
/// ink treatment with a red bar when selected.
class SidebarRow extends StatelessWidget {
  const SidebarRow({
    super.key,
    required this.title,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    return Semantics(
      button: true,
      selected: selected,
      label: count == null ? title : '$title, $count',
      child: InkWell(
        onTap: onTap,
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
          padding: const EdgeInsets.only(left: 21, right: 24),
          // The row's own label carries title and count for assistive tech.
          child: ExcludeSemantics(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: text.sidebar.copyWith(
                      color: selected ? SaiColors.onInk : SaiColors.ink,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (count case final count?)
                  Text(
                    '$count',
                    style: text.meta.copyWith(
                      color: selected ? SaiColors.onInk : SaiColors.inkFaint,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
