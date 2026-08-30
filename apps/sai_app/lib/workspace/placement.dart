import 'package:sai_core/sai_core.dart';

/// A placement a task can be moved to: the Inbox, an area, a project, or
/// a heading (with its project).
typedef Placement = ({ProjectId? project, AreaId? area, HeadingId? heading});

/// What kind of container a [PlacementOption] names.
enum PlacementKind { inbox, area, project, heading }

/// One destination the Move sheet and the inspector's Where menu offer:
/// its title, how deep it sits under the row above it, and the placement
/// a move to it writes.
class PlacementOption {
  const PlacementOption({
    required this.kind,
    required this.title,
    required this.depth,
    required this.placement,
  });

  final PlacementKind kind;
  final String title;
  final int depth;
  final Placement placement;

  /// The option as a menu line: four spaces per level, `—` before a
  /// project under its area, `·` before a heading.
  String get menuLabel {
    final indent = '    ' * depth;
    return switch (kind) {
      PlacementKind.project when depth > 0 => '$indent— $title',
      PlacementKind.heading => '$indent· $title',
      _ => '$indent$title',
    };
  }
}

/// The placement [task] has now, in the shape the options carry.
Placement placementOf(Task task) =>
    (project: task.project, area: task.area, heading: task.heading);

/// Every live destination, as the sidebar orders them (#98): the Inbox,
/// then each live area with its live projects nested and every project's
/// headings under it, then the standalone projects with theirs. Archived
/// and deleted containers are not offered — the store would refuse them.
List<PlacementOption> placementOptions(TaskProjection projection) {
  final options = <PlacementOption>[
    const PlacementOption(
      kind: PlacementKind.inbox,
      title: 'Inbox — unfiled',
      depth: 0,
      placement: (project: null, area: null, heading: null),
    ),
  ];
  final projects = projection.liveProjects();
  void project(Project p, int depth) {
    options.add(
      PlacementOption(
        kind: PlacementKind.project,
        title: p.title,
        depth: depth,
        placement: (project: p.id, area: null, heading: null),
      ),
    );
    for (final heading in projection.headingsOf(p.id)) {
      options.add(
        PlacementOption(
          kind: PlacementKind.heading,
          title: heading.title,
          depth: depth + 1,
          placement: (project: p.id, area: null, heading: heading.id),
        ),
      );
    }
  }

  for (final area in projection.liveAreas()) {
    options.add(
      PlacementOption(
        kind: PlacementKind.area,
        title: area.title,
        depth: 0,
        placement: (project: null, area: area.id, heading: null),
      ),
    );
    for (final p in projects) {
      if (projection.groupOf(p) == area.id) project(p, 1);
    }
  }
  for (final p in projects) {
    if (projection.groupOf(p) == null) project(p, 0);
  }
  return options;
}
