import 'date.dart';
import 'lists.dart';
import 'model.dart';
import 'projection.dart';
import 'sidebar.dart';
import 'views.dart';
import '../archive/blobref.dart';

/// What a client restores at launch (#76), checked against the projection:
/// the section to select, the task to reveal in it, and the areas to keep
/// folded — each only while it is still meaningful.
typedef RestoredWorkspace = ({
  SidebarSection section,
  TaskId? task,
  Set<AreaId> collapsedAreas,
});

/// Validates saved workspace state against [projection]. A list or the
/// Trash is always valid; an area, project or tag only while it exists and
/// is not deleted (archived stays browsable); anything else falls back to
/// Today and drops the task. The task is kept only while the chosen section
/// actually shows it, so a client selecting section then task never has
/// its selection cleared by its own view. Collapsed areas keep only live
/// ids. Pure: a stale preference degrades, it never throws.
RestoredWorkspace restoreWorkspace(
  TaskProjection projection, {
  required String? section,
  required String? task,
  required Iterable<String> collapsedAreas,
  required CalendarDate today,
  FinishedTaskVisibility visibility = FinishedTaskVisibility.immediate,
}) {
  final parsed = section == null ? null : sectionFromKey(section);
  final valid = parsed != null && _live(projection, parsed);
  final selected = valid ? parsed : const ListSection(TaskList.today);
  TaskId? shown;
  if (valid && task != null) {
    final id = BlobRef.tryParse(task);
    if (id != null &&
        taskView(
          projection,
          selected,
          today: today,
          visibility: visibility,
        ).tasks.any((t) => t.id == id)) {
      shown = id;
    }
  }
  final collapsed = <AreaId>{
    for (final key in collapsedAreas)
      if (BlobRef.tryParse(key) case final id?
          when projection.areas[id]?.deletedAt == null &&
              projection.areas.containsKey(id))
        id,
  };
  return (section: selected, task: shown, collapsedAreas: collapsed);
}

bool _live(TaskProjection projection, SidebarSection section) =>
    switch (section) {
      ListSection() || TrashSection() => true,
      AreaSection(:final area) => switch (projection.areas[area]) {
        Area(deletedAt: null) => true,
        _ => false,
      },
      ProjectSection(:final project) => switch (projection.projects[project]) {
        Project(deletedAt: null) => true,
        _ => false,
      },
      TagSection(:final tag) => switch (projection.tags[tag]) {
        Tag(deletedAt: null) => true,
        _ => false,
      },
    };
