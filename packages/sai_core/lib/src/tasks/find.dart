import 'date.dart';
import 'lists.dart';
import 'model.dart';
import 'projection.dart';
import 'sidebar.dart';

/// What one Quick Find row stands for (#76), in the order rows are ranked
/// when their match quality ties.
enum FindResultKind { list, trash, area, project, heading, tag, task }

/// One Quick Find row: what it is called, one line of context, and where
/// opening it lands — a section to select and, for a task, the task to
/// reveal there.
final class FindResult {
  const FindResult({
    required this.kind,
    required this.title,
    required this.section,
    this.detail,
    this.task,
  });

  final FindResultKind kind;
  final String title;
  final String? detail;
  final SidebarSection section;
  final TaskId? task;

  @override
  bool operator ==(Object other) =>
      other is FindResult &&
      other.kind == kind &&
      other.title == title &&
      other.detail == detail &&
      other.section == section &&
      other.task == task;

  @override
  int get hashCode => Object.hash(kind, title, detail, section, task);

  @override
  String toString() => 'FindResult(${kind.name}, $title, $section)';
}

/// Quick Find over one projection snapshot: the standard lists and the
/// Trash, live areas, live and archived projects, the headings of live
/// projects, live tags, and undeleted task titles. Matching folds case and
/// diacritics; rows rank exact, then prefix, then word-prefix, then
/// substring, ties by [FindResultKind] then title. A blank [query] offers
/// the lists alone. Pure and synchronous: results update as the user types.
List<FindResult> findInTasks(
  TaskProjection projection,
  String query, {
  required CalendarDate today,
  int limit = 25,
}) {
  final needle = _fold(query.trim());
  final lists = [
    for (final list in TaskList.values)
      FindResult(
        kind: FindResultKind.list,
        title: listTitle(list),
        section: ListSection(list),
      ),
    const FindResult(
      kind: FindResultKind.trash,
      title: trashTitle,
      section: TrashSection(),
    ),
  ];
  if (needle.isEmpty) return List.unmodifiable(lists.take(limit));

  final projectTitles = {
    for (final project in projection.projects.values) project.id: project.title,
  };
  final candidates = [
    ...lists,
    for (final area in projection.liveAreas())
      FindResult(
        kind: FindResultKind.area,
        title: area.title,
        section: AreaSection(area.id),
      ),
    for (final area in projection.archivedAreas())
      FindResult(
        kind: FindResultKind.area,
        title: area.title,
        detail: _archived,
        section: AreaSection(area.id),
      ),
    for (final project in projection.liveProjects()) ...[
      FindResult(
        kind: FindResultKind.project,
        title: project.title,
        detail: _areaTitle(projection, project.area),
        section: ProjectSection(project.id),
      ),
      for (final heading in projection.headingsOf(project.id))
        FindResult(
          kind: FindResultKind.heading,
          title: heading.title,
          detail: project.title,
          section: ProjectSection(project.id),
        ),
    ],
    for (final project in projection.archivedProjects())
      FindResult(
        kind: FindResultKind.project,
        title: project.title,
        detail: _archived,
        section: ProjectSection(project.id),
      ),
    for (final tag in projection.tags.values)
      if (tag.deletedAt == null)
        FindResult(
          kind: FindResultKind.tag,
          title: tag.title,
          section: TagSection(tag.id),
        ),
    for (final task in projection.tasks.values)
      if (task.deletedAt == null)
        FindResult(
          kind: FindResultKind.task,
          title: task.title,
          detail: _taskDetail(projection, task, projectTitles, today),
          section: homeSection(task, today: today),
          task: task.id,
        ),
  ];

  final ranked = <(int, FindResult)>[
    for (final candidate in candidates)
      if (_rank(_fold(candidate.title), needle) case final rank?)
        (rank, candidate),
  ];
  ranked.sort((a, b) {
    final byRank = a.$1.compareTo(b.$1);
    if (byRank != 0) return byRank;
    final byKind = a.$2.kind.index.compareTo(b.$2.kind.index);
    if (byKind != 0) return byKind;
    final byTitle = _fold(a.$2.title).compareTo(_fold(b.$2.title));
    if (byTitle != 0) return byTitle;
    return '${a.$2.task ?? a.$2.section}'.compareTo(
      '${b.$2.task ?? b.$2.section}',
    );
  });
  return List.unmodifiable([for (final (_, r) in ranked.take(limit)) r]);
}

/// The section that shows [task] today: the Trash when deleted, the Logbook
/// when closed, else its project or area, else the list it lives in. The
/// order matters — a closed task is filtered out of its project's view.
SidebarSection homeSection(Task task, {required CalendarDate today}) {
  if (task.deletedAt != null) return const TrashSection();
  if (task.status != TaskStatus.open) {
    return const ListSection(TaskList.logbook);
  }
  if (task.project case final project?) return ProjectSection(project);
  if (task.area case final area?) return AreaSection(area);
  return ListSection(listOf(task, today) ?? TaskList.inbox);
}

const _archived = 'Archived';

String? _areaTitle(TaskProjection projection, AreaId? area) =>
    area == null ? null : projection.areas[area]?.title;

String _taskDetail(
  TaskProjection projection,
  Task task,
  Map<ProjectId, String> projectTitles,
  CalendarDate today,
) {
  if (task.status != TaskStatus.open) return listTitle(TaskList.logbook);
  if (task.project case final project?) {
    if (projectTitles[project] case final title?) return title;
  }
  if (task.area case final area?) {
    if (projection.areas[area]?.title case final title?) return title;
  }
  return listTitle(listOf(task, today) ?? TaskList.inbox);
}

/// 0 exact, 1 prefix, 2 a word starts with it, 3 anywhere; null no match.
int? _rank(String haystack, String needle) {
  if (haystack == needle) return 0;
  if (haystack.startsWith(needle)) return 1;
  final at = haystack.indexOf(needle);
  if (at < 0) return null;
  return haystack[at - 1] == ' ' ? 2 : 3;
}

/// Lower-case with the Latin diacritics a task title is likely to carry
/// folded to their base letters, so `zazolc` finds `Zażółć`.
String _fold(String text) {
  final buffer = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    buffer.write(_diacritics[char] ?? char);
  }
  return buffer.toString().replaceAll(RegExp(r'\s+'), ' ');
}

const _diacritics = <String, String>{
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ä': 'a',
  'ã': 'a',
  'å': 'a',
  'ą': 'a',
  'æ': 'ae',
  'ç': 'c',
  'ć': 'c',
  'č': 'c',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ę': 'e',
  'ě': 'e',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ł': 'l',
  'ñ': 'n',
  'ń': 'n',
  'ň': 'n',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'ö': 'o',
  'õ': 'o',
  'ø': 'o',
  'œ': 'oe',
  'ř': 'r',
  'ś': 's',
  'š': 's',
  'ß': 'ss',
  'ť': 't',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ů': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ź': 'z',
  'ż': 'z',
  'ž': 'z',
};
