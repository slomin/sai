import '../archive/blobref.dart';
import 'date.dart';
import 'lists.dart';
import 'model.dart';
import 'projection.dart';

/// One place a client's attention can rest: a standard list, the Trash,
/// an area, a project, or a tag. Value classes, so selection state compares
/// by meaning rather than by instance.
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

/// The open tasks carrying one tag (#76). Reached through Quick Find, not
/// the sidebar — [sidebarModel] lists no tags, so while a tag is selected
/// no sidebar row is highlighted; the pane title names the tag.
final class TagSection extends SidebarSection {
  const TagSection(this.tag);

  final TagId tag;

  @override
  bool operator ==(Object other) => other is TagSection && other.tag == tag;

  @override
  int get hashCode => Object.hash(TagSection, tag);

  @override
  String toString() => 'TagSection($tag)';
}

/// The stable text form of a section — what a settings file stores (#76):
/// `list:<name>`, `trash`, `area:<id>`, `project:<id>`, `tag:<id>`.
String sectionKey(SidebarSection section) => switch (section) {
  ListSection(:final list) => 'list:${list.name}',
  TrashSection() => 'trash',
  AreaSection(:final area) => 'area:$area',
  ProjectSection(:final project) => 'project:$project',
  TagSection(:final tag) => 'tag:$tag',
};

/// The inverse of [sectionKey]; null for anything this sai does not
/// understand — a stale preference is never a reason to fail.
SidebarSection? sectionFromKey(String key) {
  if (key == 'trash') return const TrashSection();
  final colon = key.indexOf(':');
  if (colon <= 0) return null;
  final kind = key.substring(0, colon);
  final rest = key.substring(colon + 1);
  if (kind == 'list') {
    for (final list in TaskList.values) {
      if (list.name == rest) return ListSection(list);
    }
    return null;
  }
  final id = BlobRef.tryParse(rest);
  if (id == null) return null;
  return switch (kind) {
    'area' => AreaSection(id),
    'project' => ProjectSection(id),
    'tag' => TagSection(id),
    _ => null,
  };
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
    this.archived = const [],
  });

  final List<SidebarEntry> lists;
  final SidebarEntry trash;
  final List<SidebarArea> areas;
  final List<SidebarEntry> projects;

  /// Archived areas then archived projects (#74), each in its persisted
  /// order — the rows an Archived group shows so a client can unarchive.
  final List<SidebarEntry> archived;

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
/// — a project whose area is deleted or archived is listed standalone
/// rather than hidden. Containers follow the projection's persisted order
/// (#74); deleted and archived containers are left out of the main groups,
/// the archived ones listed under [SidebarModel.archived]. List counts
/// follow the view unions of [TaskProjection.list], container counts are
/// open, visible tasks. Shared here so the clients cannot drift apart.
SidebarModel sidebarModel(
  TaskProjection projection, {
  required CalendarDate today,
}) {
  final areas = projection.liveAreas();
  final projects = projection.liveProjects();

  SidebarEntry projectEntry(Project project, {bool archived = false}) =>
      SidebarEntry(
        project.title,
        projection.inProject(project.id, archived: archived).length,
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
              if (projection.groupOf(project) == area.id) projectEntry(project),
          ],
        ),
    ],
    projects: [
      for (final project in projects)
        if (projection.groupOf(project) == null) projectEntry(project),
    ],
    archived: [
      for (final area in projection.archivedAreas())
        SidebarEntry(
          area.title,
          projection.inArea(area.id, archived: true).length,
          AreaSection(area.id),
        ),
      for (final project in projection.archivedProjects())
        projectEntry(project, archived: true),
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
  AreaSection(:final area) => projection.inArea(area, archived: true),
  ProjectSection(:final project) => projection.inProject(
    project,
    archived: true,
  ),
  TagSection(:final tag) => projection.withTag(tag),
};

/// The heading a main pane shows for [section]. A container that is
/// deleted, or that the projection does not know, degrades instead of
/// throwing — a stale selection is a display problem, not a crash. An
/// archived container keeps its name: it is still browsable.
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
      TagSection(:final tag) => switch (projection.tags[tag]) {
        Tag(deletedAt: null, :final title) => title,
        _ => _unknown,
      },
    };

const _unknown = '(deleted)';
