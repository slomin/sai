import 'package:flutter/material.dart';
import 'package:sai_core/sai_core.dart';

import '../workspace/task_row_chips.dart';
import 'field_row.dart';

/// A placement the WHERE menu offers: the Inbox, an area, a project, or
/// a heading of the task's own project.
typedef Placement = ({ProjectId? project, AreaId? area, HeadingId? heading});

/// The WHERE row: the Inbox, every live area and project (nested under
/// their area, as the sidebar shows them), and — for a task already in a
/// project — that project's headings. Choosing one is a move.
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
    final items = <Widget>[
      MenuItemButton(
        onPressed: () => onMove((project: null, area: null, heading: null)),
        child: const Text('Inbox — unfiled'),
      ),
    ];
    final projects = projection.liveProjects();
    void project(Project p, {bool nested = false}) {
      items.add(
        MenuItemButton(
          onPressed: () => onMove((project: p.id, area: null, heading: null)),
          child: Text('${nested ? '    — ' : ''}${p.title}'),
        ),
      );
      if (p.id == task.project) {
        for (final heading in projection.headingsOf(p.id)) {
          items.add(
            MenuItemButton(
              onPressed: () =>
                  onMove((project: p.id, area: null, heading: heading.id)),
              child: Text('${nested ? '        ' : '    '}· ${heading.title}'),
            ),
          );
        }
      }
    }

    for (final area in projection.liveAreas()) {
      items.add(
        MenuItemButton(
          onPressed: () =>
              onMove((project: null, area: area.id, heading: null)),
          child: Text(area.title),
        ),
      );
      for (final p in projects) {
        if (projection.groupOf(p) == area.id) project(p, nested: true);
      }
    }
    for (final p in projects) {
      if (projection.groupOf(p) == null) project(p);
    }
    return MenuAnchor(
      menuChildren: items,
      builder: (context, controller, _) => InspectorValueButton(
        label: 'Where',
        value: containerLabel(projection, task) ?? 'Inbox — unfiled',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
