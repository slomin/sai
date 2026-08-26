import 'package:flutter/material.dart';

import '../theme/sai_tokens.dart';
import '../widgets/eyebrow.dart';

/// A group's label and its count — a day in Upcoming or the Logbook, an
/// area, a project or a heading elsewhere.
class TaskSectionHeader extends StatelessWidget {
  const TaskSectionHeader({super.key, required this.label, required this.meta});

  final String label;
  final String meta;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(28, 22, 28, 8),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: SaiColors.rule)),
        ),
        child: Row(
          children: [
            Expanded(child: Eyebrow(label, dim: true)),
            const SizedBox(width: 12),
            Eyebrow(meta, dim: true),
          ],
        ),
      ),
    );
  }
}
