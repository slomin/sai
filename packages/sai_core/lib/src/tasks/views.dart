import 'date.dart';
import 'lists.dart';
import 'model.dart';
import 'projection.dart';
import 'sidebar.dart';

/// The semantic role of one section in a task view.
enum TaskViewSectionKind { flat, loose, area, project, heading, day }

/// One immutable row group in a [TaskView]. Container and day identities are
/// carried separately from the display title so clients do not parse labels.
final class TaskViewSection {
  TaskViewSection({
    required this.kind,
    required this.title,
    this.day,
    this.area,
    this.project,
    this.heading,
    required List<Task> tasks,
  }) : tasks = List.unmodifiable(tasks);

  final TaskViewSectionKind kind;
  final String title;
  final CalendarDate? day;
  final AreaId? area;
  final ProjectId? project;
  final HeadingId? heading;
  final List<Task> tasks;

  @override
  bool operator ==(Object other) =>
      other is TaskViewSection &&
      other.kind == kind &&
      other.title == title &&
      other.day == day &&
      other.area == area &&
      other.project == project &&
      other.heading == heading &&
      _sameList(other.tasks, tasks);

  @override
  int get hashCode => Object.hash(
    kind,
    title,
    day,
    area,
    project,
    heading,
    Object.hashAll(tasks),
  );
}

/// The immutable shared view model for one selected sidebar section.
final class TaskView {
  TaskView({
    required this.section,
    required this.title,
    required List<TaskViewSection> sections,
  }) : sections = List.unmodifiable(sections);

  final SidebarSection section;
  final String title;
  final List<TaskViewSection> sections;

  /// Every task in display order, flattened for clients that cannot render
  /// nested section chrome.
  List<Task> get tasks =>
      List.unmodifiable([for (final section in sections) ...section.tasks]);

  @override
  bool operator ==(Object other) =>
      other is TaskView &&
      other.section == section &&
      other.title == title &&
      _sameList(other.sections, sections);

  @override
  int get hashCode => Object.hash(section, title, Object.hashAll(sections));
}

/// Builds the shared view for [section] from one projection snapshot.
TaskView taskView(
  TaskProjection projection,
  SidebarSection section, {
  required CalendarDate today,
}) {
  final title = sectionTitle(projection, section);
  final sections = switch (section) {
    ListSection(:final list) => _listSections(projection, list, today),
    TrashSection() => [
      TaskViewSection(
        kind: TaskViewSectionKind.flat,
        title: trashTitle,
        tasks: projection.trash(),
      ),
    ],
    AreaSection(:final area) => _areaSections(projection, area),
    ProjectSection(:final project) => _selectedProjectSections(
      projection,
      project,
    ),
  };
  return TaskView(section: section, title: title, sections: sections);
}

List<TaskViewSection> _listSections(
  TaskProjection projection,
  TaskList list,
  CalendarDate today,
) => switch (list) {
  TaskList.inbox || TaskList.today => [
    TaskViewSection(
      kind: TaskViewSectionKind.flat,
      title: listTitle(list),
      tasks: projection.list(list, today: today),
    ),
  ],
  TaskList.upcoming => _upcomingSections(projection, today),
  TaskList.anytime ||
  TaskList.someday => _hierarchySections(projection, list, today),
  TaskList.logbook => _logbookSections(projection, today),
};

List<TaskViewSection> _upcomingSections(
  TaskProjection projection,
  CalendarDate today,
) {
  final days = <CalendarDate, List<Task>>{};
  for (final task in projection.list(TaskList.upcoming, today: today)) {
    final start = switch (task.when) {
      TaskWhenDate(:final date) when date > today => date,
      _ => null,
    };
    final day = start ?? task.deadline!;
    days.putIfAbsent(day, () => []).add(task);
  }
  final ordered = days.keys.toList()..sort();
  return [
    for (final day in ordered)
      TaskViewSection(
        kind: TaskViewSectionKind.day,
        title: day.toString(),
        day: day,
        tasks: days[day]!,
      ),
  ];
}

List<TaskViewSection> _logbookSections(
  TaskProjection projection,
  CalendarDate today,
) {
  final days = <CalendarDate, List<Task>>{};
  for (final task in projection.list(TaskList.logbook, today: today)) {
    final finished = task.cancelledAt ?? task.completedAt!;
    final day = CalendarDate.fromLocal(finished.toLocal());
    days.putIfAbsent(day, () => []).add(task);
  }
  final ordered = days.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final day in ordered)
      TaskViewSection(
        kind: TaskViewSectionKind.day,
        title: day.toString(),
        day: day,
        tasks: days[day]!,
      ),
  ];
}

List<TaskViewSection> _hierarchySections(
  TaskProjection projection,
  TaskList list,
  CalendarDate today,
) {
  final included = {
    for (final task in projection.list(list, today: today)) task.id,
  };
  List<Task> keep(Iterable<Task> tasks) => [
    for (final task in tasks)
      if (included.contains(task.id)) task,
  ];

  final sidebar = sidebarModel(projection, today: today);
  final sections = <TaskViewSection>[
    TaskViewSection(
      kind: TaskViewSectionKind.loose,
      title: listTitle(list),
      tasks: keep(
        projection
            .list(list, today: today)
            .where(
              (task) =>
                  task.project == null &&
                  task.area == null &&
                  task.heading == null,
            ),
      ),
    ),
  ];
  for (final areaRow in sidebar.areas) {
    final area = (areaRow.entry.section as AreaSection).area;
    final model = projection.areas[area]!;
    sections.add(
      TaskViewSection(
        kind: TaskViewSectionKind.area,
        title: model.title,
        area: area,
        tasks: keep(projection.inArea(area)),
      ),
    );
    for (final projectRow in areaRow.projects) {
      final project = (projectRow.section as ProjectSection).project;
      sections.addAll(_projectSections(projection, project, keep));
    }
  }
  for (final projectRow in sidebar.projects) {
    final project = (projectRow.section as ProjectSection).project;
    sections.addAll(_projectSections(projection, project, keep));
  }
  return sections;
}

List<TaskViewSection> _areaSections(TaskProjection projection, AreaId area) {
  final model = projection.areas[area];
  if (model == null || model.deletedAt != null) return const [];
  final sections = <TaskViewSection>[
    TaskViewSection(
      kind: TaskViewSectionKind.area,
      title: model.title,
      area: area,
      tasks: projection.inArea(area, archived: true),
    ),
  ];
  final projects = [
    for (final project in projection.liveProjects())
      if (project.area == area) project,
  ];
  for (final project in projects) {
    sections.addAll(
      _projectSections(projection, project.id, (tasks) => tasks.toList()),
    );
  }
  return sections;
}

List<TaskViewSection> _selectedProjectSections(
  TaskProjection projection,
  ProjectId project,
) {
  final model = projection.projects[project];
  if (model == null || model.deletedAt != null) return const [];
  return _projectSections(projection, project, (tasks) => tasks.toList());
}

List<TaskViewSection> _projectSections(
  TaskProjection projection,
  ProjectId projectId,
  List<Task> Function(Iterable<Task>) keep,
) {
  final project = projection.projects[projectId]!;
  final all = projection.inProject(projectId, archived: true);
  final sections = <TaskViewSection>[
    TaskViewSection(
      kind: TaskViewSectionKind.project,
      title: project.title,
      project: projectId,
      tasks: keep(all.where((task) => task.heading == null)),
    ),
  ];
  for (final heading in projection.headingsOf(projectId)) {
    sections.add(
      TaskViewSection(
        kind: TaskViewSectionKind.heading,
        title: heading.title,
        project: projectId,
        heading: heading.id,
        tasks: keep(all.where((task) => task.heading == heading.id)),
      ),
    );
  }
  return sections;
}

bool _sameList<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
