import 'date.dart';
import 'lists.dart';
import 'model.dart';
import 'projection.dart';

/// One place a client's attention can rest: a standard list, the Trash,
/// an area, or a project. Value classes, so selection state compares by
/// meaning rather than by instance.
sealed class SidebarSection {
  const SidebarSection();
}

final class ListSection extends SidebarSection {
  const ListSection(this.list);

  final TaskList list;

  @override
  bool operator ==(Object other) => other is ListSection && other.list == list;

  @override
  int get hashCode => Object.hash(ListSection, list);

  @override
  String toString() => 'ListSection(${list.name})';
}

final class TrashSection extends SidebarSection {
  const TrashSection();

  @override
  bool operator ==(Object other) => other is TrashSection;

  @override
  int get hashCode => (TrashSection).hashCode;

  @override
  String toString() => 'TrashSection()';
}

final class AreaSection extends SidebarSection {
  const AreaSection(this.area);

  final AreaId area;

  @override
  bool operator ==(Object other) => other is AreaSection && other.area == area;

  @override
  int get hashCode => Object.hash(AreaSection, area);

  @override
  String toString() => 'AreaSection($area)';
}

final class ProjectSection extends SidebarSection {
  const ProjectSection(this.project);

  final ProjectId project;

  @override
  bool operator ==(Object other) =>
      other is ProjectSection && other.project == project;

  @override
  int get hashCode => Object.hash(ProjectSection, project);

  @override
  String toString() => 'ProjectSection($project)';
}

/// One sidebar row: what it is called, how many tasks it holds, and the
/// section selecting it reveals.
final class SidebarEntry {
  const SidebarEntry(this.title, this.count, this.section);

  final String title;
  final int count;
  final SidebarSection section;

  /// The row both clients render, e.g. `Inbox (2)`.
  String get label => '$title ($count)';
}

/// An area row with the project rows nested under it.
final class SidebarArea {
  const SidebarArea(this.entry, this.projects);

  final SidebarEntry entry;
  final List<SidebarEntry> projects;
}

/// Everything a sidebar shows: the standard lists, the Trash, the areas
/// with their projects, and the projects that belong to no area.
final class SidebarModel {
  const SidebarModel({
    required this.lists,
    required this.trash,
    required this.areas,
    required this.projects,
  });

  final List<SidebarEntry> lists;
  final SidebarEntry trash;
  final List<SidebarArea> areas;
  final List<SidebarEntry> projects;

  /// Every row top to bottom, areas immediately followed by their
  /// projects — the order a client that cannot nest (or a keyboard walking
  /// the sidebar) uses.
  List<SidebarEntry> get rows => [
    ...lists,
    trash,
    for (final area in areas) ...[area.entry, ...area.projects],
    ...projects,
  ];
}

/// The sidebar as of [today]: lists in [TaskList.values] order, then the
/// Trash, then the areas and their projects, then the standalone projects
/// — a project whose area is deleted is listed standalone rather than
/// hidden. Containers sort by title, case-insensitively, ties broken by
/// id; deleted containers are left out. List counts follow the view
/// unions of [TaskProjection.list], container counts are open, visible
/// tasks. Manual ordering is #20's. Shared here so the clients cannot
/// drift apart.
SidebarModel sidebarModel(
  TaskProjection projection, {
  required CalendarDate today,
}) {
  final areas = [
    for (final area in projection.areas.values)
      if (area.deletedAt == null) area,
  ]..sort((a, b) => _byTitle(a.title, a.id, b.title, b.id));
  final live = {for (final area in areas) area.id};
  final projects = [
    for (final project in projection.projects.values)
      if (project.deletedAt == null) project,
  ]..sort((a, b) => _byTitle(a.title, a.id, b.title, b.id));

  SidebarEntry projectEntry(Project project) => SidebarEntry(
    project.title,
    projection.inProject(project.id).length,
    ProjectSection(project.id),
  );

  return SidebarModel(
    lists: [
      for (final list in TaskList.values)
        SidebarEntry(
          listTitle(list),
          projection.list(list, today: today).length,
          ListSection(list),
        ),
    ],
    trash: SidebarEntry(
      trashTitle,
      projection.trash().length,
      const TrashSection(),
    ),
    areas: [
      for (final area in areas)
        SidebarArea(
          SidebarEntry(
            area.title,
            projection.inArea(area.id).length,
            AreaSection(area.id),
          ),
          [
            for (final project in projects)
              if (project.area == area.id) projectEntry(project),
          ],
        ),
    ],
    projects: [
      for (final project in projects)
        if (!live.contains(project.area)) projectEntry(project),
    ],
  );
}

/// The tasks [section] reveals, in the projection's order.
List<Task> sectionTasks(
  TaskProjection projection,
  SidebarSection section, {
  required CalendarDate today,
}) => switch (section) {
  ListSection(:final list) => projection.list(list, today: today),
  TrashSection() => projection.trash(),
  AreaSection(:final area) => projection.inArea(area),
  ProjectSection(:final project) => projection.inProject(project),
};

/// The heading a main pane shows for [section]. A container that is
/// deleted, or that the projection does not know, degrades instead of
/// throwing — a stale selection is a display problem, not a crash.
String sectionTitle(TaskProjection projection, SidebarSection section) =>
    switch (section) {
      ListSection(:final list) => listTitle(list),
      TrashSection() => trashTitle,
      AreaSection(:final area) => switch (projection.areas[area]) {
        Area(deletedAt: null, :final title) => title,
        _ => _unknown,
      },
      ProjectSection(:final project) => switch (projection.projects[project]) {
        Project(deletedAt: null, :final title) => title,
        _ => _unknown,
      },
    };

const _unknown = '(deleted)';

int _byTitle(String aTitle, Object aId, String bTitle, Object bId) {
  final byTitle = aTitle.toLowerCase().compareTo(bTitle.toLowerCase());
  return byTitle != 0 ? byTitle : aId.toString().compareTo(bId.toString());
}
