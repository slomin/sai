import 'package:flutter/material.dart';
import 'package:sai_core/sai_core.dart';

import '../workspace/placement.dart';
import '../workspace/task_row_chips.dart';
import 'field_row.dart';

export '../workspace/placement.dart' show Placement;

/// The WHERE row: every destination [placementOptions] offers — the
/// Inbox, each live area and project (nested under their area, as the
/// sidebar shows them) and every live project's headings (#98).
/// Choosing one is a move.
class WhereMenu extends StatelessWidget {
  const WhereMenu({
    super.key,
    required this.task,
    required this.projection,
    required this.onMove,
  });

  final Task task;
  final TaskProjection projection;
  final ValueChanged<Placement> onMove;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        for (final option in placementOptions(projection))
          MenuItemButton(
            onPressed: () => onMove(option.placement),
            child: Text(option.menuLabel),
          ),
      ],
      builder: (context, controller, _) => InspectorValueButton(
        label: 'Where',
        value: containerLabel(projection, task) ?? 'Inbox — unfiled',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
