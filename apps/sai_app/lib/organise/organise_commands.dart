import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../workspace/task_commands.dart';

/// The organisation commands (#74): areas, projects, headings and tags —
/// create, rename, nudge up or down in the persisted order, archive and
/// delete. A container delete first moves the tasks it holds when asked:
/// every step is its own event and its own undo entry, and the first
/// refusal stops the run and reports.
final organiseCommandsProvider = Provider<OrganiseCommands>(
  OrganiseCommands.new,
);

class OrganiseCommands {
  OrganiseCommands(this._ref);

  final Ref _ref;

  TaskProjection get _projection =>
      _ref.read(tasksProvider.notifier).store.projection;

  // --- create ---

  Future<AreaId?> createArea(String title) =>
      _create('new area', (store) => store.createArea(title: title));

  Future<ProjectId?> createProject(String title, {AreaId? area}) => _create(
    'new project',
    (store) => store.createProject(title: title, area: area),
  );

  /// The id, or null when the store refused — a blank title is refused
  /// here, trimmed, so whitespace never reaches the log as a name.
  Future<HeadingId?> createHeading(ProjectId project, String title) => _create(
    'new heading',
    (store) => store.createHeading(project: project, title: title.trim()),
  );

  /// [createHeading] for the prompt (#96): null on success, otherwise the
  /// reason, which the prompt shows beside the title it keeps.
  Future<String?> tryCreateHeading(ProjectId project, String title) =>
      tryStoreCommand(
        _ref,
        'new heading',
        (store) => store.createHeading(project: project, title: title.trim()),
      );

  Future<TagId?> createTag(String title) =>
      _create('new tag', (store) => store.createTag(title: title));

  // --- rename ---

  Future<bool> renameArea(AreaId area, String title) => runStoreCommand(
    _ref,
    'rename',
    (store) => store.editArea(area, title: Patch(title)),
  );

  Future<bool> renameProject(ProjectId project, String title) =>
      runStoreCommand(
        _ref,
        'rename',
        (store) => store.editProject(project, title: Patch(title)),
      );

  Future<bool> renameHeading(HeadingId heading, String title) =>
      runStoreCommand(
        _ref,
        'rename',
        (store) => store.editHeading(heading, title: Patch(title)),
      );

  Future<bool> renameTag(TagId tag, String title) => runStoreCommand(
    _ref,
    'rename',
    (store) => store.editTag(tag, title: Patch(title)),
  );

  // --- order ---

  /// Moves [area] one step up ([by] -1) or down (+1) among the live areas;
  /// false at either end.
  Future<bool> nudgeArea(AreaId area, int by) {
    final ids = [for (final a in _projection.liveAreas()) a.id];
    final after = _anchor(ids, area, by);
    if (after == _noMove) return Future.value(false);
    return runStoreCommand(
      _ref,
      'reorder',
      (store) => store.reorderArea(area, after: after),
    );
  }

  /// Moves [project] within its group — its live area, or the standalone
  /// projects.
  Future<bool> nudgeProject(ProjectId project, int by) {
    final projection = _projection;
    final target = projection.projects[project];
    if (target == null) return Future.value(false);
    final group = projection.groupOf(target);
    final ids = [
      for (final p in projection.liveProjects())
        if (projection.groupOf(p) == group) p.id,
    ];
    final after = _anchor(ids, project, by);
    if (after == _noMove) return Future.value(false);
    return runStoreCommand(
      _ref,
      'reorder',
      (store) => store.reorderProject(project, after: after),
    );
  }

  Future<bool> nudgeHeading(HeadingId heading, int by) {
    final projection = _projection;
    final target = projection.headings[heading];
    if (target == null) return Future.value(false);
    final ids = [for (final h in projection.headingsOf(target.project)) h.id];
    final after = _anchor(ids, heading, by);
    if (after == _noMove) return Future.value(false);
    return runStoreCommand(
      _ref,
      'reorder',
      (store) => store.reorderHeading(heading, after: after),
    );
  }

  // --- archive ---

  Future<bool> archiveArea(AreaId area) =>
      runStoreCommand(_ref, 'archive', (store) => store.archiveArea(area));

  Future<bool> unarchiveArea(AreaId area) =>
      runStoreCommand(_ref, 'unarchive', (store) => store.unarchiveArea(area));

  Future<bool> archiveProject(ProjectId project) => runStoreCommand(
    _ref,
    'archive',
    (store) => store.archiveProject(project),
  );

  Future<bool> unarchiveProject(ProjectId project) => runStoreCommand(
    _ref,
    'unarchive',
    (store) => store.unarchiveProject(project),
  );

  // --- delete ---

  /// Deletes [area]; with [moveTasks], its direct tasks go to the Inbox
  /// first (its projects stay, listed standalone).
  Future<bool> deleteArea(AreaId area, {required bool moveTasks}) async {
    if (moveTasks) {
      for (final task in _projection.inArea(area, archived: true)) {
        if (!await _move(task.id)) return false;
      }
    }
    return runStoreCommand(_ref, 'delete', (store) => store.deleteArea(area));
  }

  /// Deletes [project]; with [moveTasks], every task in it — headed or
  /// not — goes to the Inbox first.
  Future<bool> deleteProject(
    ProjectId project, {
    required bool moveTasks,
  }) async {
    if (moveTasks) {
      for (final task in _projection.inProject(project, archived: true)) {
        if (!await _move(task.id)) return false;
      }
    }
    return runStoreCommand(
      _ref,
      'delete',
      (store) => store.deleteProject(project),
    );
  }

  /// Deletes [heading]; with [moveTasks], its tasks stay in the project,
  /// unheaded.
  Future<bool> deleteHeading(
    HeadingId heading, {
    required bool moveTasks,
  }) async {
    final target = _projection.headings[heading];
    if (target == null) return false;
    if (moveTasks) {
      for (final task in _projection.underHeading(heading, archived: true)) {
        if (!await _move(task.id, project: target.project)) return false;
      }
    }
    return runStoreCommand(
      _ref,
      'delete',
      (store) => store.deleteHeading(heading),
    );
  }

  Future<bool> deleteTag(TagId tag) =>
      runStoreCommand(_ref, 'delete', (store) => store.deleteTag(tag));

  /// How many open tasks [section]'s container holds — what a delete
  /// dialog offers to move.
  int taskCount(SidebarSection section) => switch (section) {
    AreaSection(:final area) => _projection.inArea(area, archived: true).length,
    ProjectSection(:final project) =>
      _projection.inProject(project, archived: true).length,
    _ => 0,
  };

  Future<bool> _move(TaskId task, {ProjectId? project}) => runStoreCommand(
    _ref,
    'move',
    (store) => store.moveTask(task, project: project),
  );

  Future<T?> _create<T>(
    String verb,
    Future<T> Function(TaskStore store) act,
  ) async {
    T? id;
    final ok = await runStoreCommand(_ref, verb, (store) async {
      id = await act(store);
    });
    return ok ? id : null;
  }
}

/// A sentinel: the nudge would not move anything.
final _noMove = BlobRef.sha256OfBytes(const [0]);

/// The anchor for moving [id] by [by] steps inside [ids]: the id it lands
/// after, null for first, or [_noMove] when it is already at that end.
BlobRef? _anchor(List<BlobRef> ids, BlobRef id, int by) {
  final index = ids.indexOf(id);
  if (index < 0) return _noMove;
  final to = index + by;
  if (to < 0 || to >= ids.length) return _noMove;
  final without = [...ids]..removeAt(index);
  return to == 0 ? null : without[to - 1];
}
