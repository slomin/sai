import 'package:flutter/material.dart';

import '../theme/sai_tokens.dart';
import '../widgets/eyebrow.dart';

/// A group's label and its count — a day in Upcoming or the Logbook, an
/// area, a project or a heading elsewhere.
class TaskSectionHeader extends StatefulWidget {
  const TaskSectionHeader({
    super.key,
    required this.label,
    required this.meta,
    this.leading,
    this.trailing,
  });

  final String label;
  final String meta;

  /// A heading's drag handle (#98), before the label; faint until the
  /// header is hovered.
  final Widget? leading;

  /// A heading's menu button, outside the header's own semantics.
  final Widget? trailing;

  @override
  State<TaskSectionHeader> createState() => _TaskSectionHeaderState();
}

class _TaskSectionHeaderState extends State<TaskSectionHeader> {
  var _hovered = false;

  @override
  Widget build(BuildContext context) {
    final leading = widget.leading;
    final trailing = widget.trailing;
    return Semantics(
      header: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Container(
          padding: EdgeInsets.fromLTRB(leading == null ? 28 : 12, 22, 28, 8),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: SaiColors.rule)),
          ),
          child: Row(
            children: [
              if (leading != null) ...[
                Opacity(
                  opacity: _hovered ? 1 : 0.4,
                  alwaysIncludeSemantics: true,
                  child: leading,
                ),
                const SizedBox(width: 4),
              ],
              Expanded(child: Eyebrow(widget.label, dim: true)),
              const SizedBox(width: 12),
              Eyebrow(widget.meta, dim: true),
              if (trailing != null) ...[const SizedBox(width: 6), trailing],
            ],
          ),
        ),
      ),
    );
  }
}
