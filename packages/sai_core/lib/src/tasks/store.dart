import 'dart:async';

import '../archive/archive.dart';
import '../archive/event.dart';
import 'date.dart';
import 'events.dart';
import 'model.dart';
import 'projection.dart';

/// The event-sourced task store (ADR 0004): every command is an archive
/// event first — sealed, appended, fsynced — and only then applied to the
/// in-memory [projection]. There is no other write path.
///
/// One store per process. A concurrent writer's appends become visible on
/// [reload] or the next open, not live; see the model doc.
final class TaskStore {
  TaskStore._(this._archive, this.source, this._projection);

  /// Opens the store over [archive] by replaying the whole log.
  ///
  /// [source] names the writing client on every line, e.g.
  /// [EventSources.tui].
  static Future<TaskStore> open(
    Archive archive, {
    required String source,
  }) async {
    final events = await archive.events().toList();
    return TaskStore._(archive, source, TaskProjection.replay(events));
  }

  final Archive _archive;

  /// The `source` written on every event this store appends.
  final String source;

  TaskProjection _projection;

  final _changes = StreamController<TaskProjection>.broadcast();

  /// The current state. Replaced (never mutated) as commands apply.
  TaskProjection get projection => _projection;

  /// The projection after each command this store commits.
  Stream<TaskProjection> get changes => _changes.stream;

  /// Rebuilds the projection from the log — how appends made by another
  /// process (or another store) become visible.
  Future<void> reload() async {
    final events = await _archive.events().toList();
    _projection = TaskProjection.replay(events);
    _changes.add(_projection);
  }

  /// Closes the [changes] stream. The archive is not touched — its owner
  /// closes it.
  void dispose() {
    _changes.close();
  }

  /// Validate → append → apply → notify. Validation applies the event to
  /// the current projection under a tentative seal, so a command the
  /// reducer would refuse never reaches the log.
  Future<StoredEvent> _commit(TaskEvent event, Attribution by) async {
    final draft = event.toDraft(source: source, by: by);
    final tentative = Event.seal(
      draft,
      prev: _projection.lastEventId,
      ts: DateTime.timestamp(),
    );
    _projection.apply(StoredEvent(id: tentative.deriveId(), event: tentative));
    final stored = await _archive.append(draft);
    _projection = _projection.apply(stored);
    _changes.add(_projection);
    return stored;
  }

  // --- tasks ---

  Future<TaskId> createTask({
    required String title,
    String notes = '',
    TaskWhen when = TaskWhen.none,
    CalendarDate? deadline,
    ProjectId? project,
    AreaId? area,
    HeadingId? heading,
    List<TagId> tags = const [],
    List<ChecklistItem> checklist = const [],
    DateTime? createdAt,
    ExternalRef? external,
    Attribution by = const Attribution.user(),
  }) async => (await _commit(
    TaskCreated(
      title: title,
      notes: notes,
      when: when,
      deadline: deadline,
      project: project,
      area: area,
      heading: heading,
      tags: tags,
      checklist: checklist,
      createdAt: createdAt,
      external: external,
    ),
    by,
  )).id;

  Future<void> editTask(
    TaskId task, {
    Patch<String>? title,
    Patch<String>? notes,
    Patch<TaskWhen>? when,
    Patch<CalendarDate?>? deadline,
    Patch<List<TagId>>? tags,
    Attribution by = const Attribution.user(),
  }) => _commit(
    TaskEdited(
      task,
      title: title,
      notes: notes,
      when: when,
      deadline: deadline,
      tags: tags,
    ),
    by,
  );

  Future<void> moveTask(
    TaskId task, {
    ProjectId? project,
    AreaId? area,
    HeadingId? heading,
    Attribution by = const Attribution.user(),
  }) => _commit(
    TaskMoved(task, project: project, area: area, heading: heading),
    by,
  );

  Future<void> completeTask(
    TaskId task, {
    DateTime? at,
    Attribution by = const Attribution.user(),
  }) => _commit(TaskCompleted(task, at: at), by);

  Future<void> cancelTask(
    TaskId task, {
    DateTime? at,
    Attribution by = const Attribution.user(),
  }) => _commit(TaskCancelled(task, at: at), by);

  Future<void> reopenTask(
    TaskId task, {
    Attribution by = const Attribution.user(),
  }) => _commit(TaskReopened(task), by);

  Future<void> deleteTask(
    TaskId task, {
    Attribution by = const Attribution.user(),
  }) => _commit(TaskDeleted(task), by);

  Future<void> restoreTask(
    TaskId task, {
    Attribution by = const Attribution.user(),
  }) => _commit(TaskRestored(task), by);

  Future<void> setChecklist(
    TaskId task,
    List<ChecklistItem> items, {
    Attribution by = const Attribution.user(),
  }) => _commit(TaskChecklistSet(task, items), by);

  // --- areas ---

  Future<AreaId> createArea({
    required String title,
    DateTime? createdAt,
    ExternalRef? external,
    Attribution by = const Attribution.user(),
  }) async => (await _commit(
    AreaCreated(title: title, createdAt: createdAt, external: external),
    by,
  )).id;

  Future<void> editArea(
    AreaId area, {
    Patch<String>? title,
    Attribution by = const Attribution.user(),
  }) => _commit(AreaEdited(area, title: title), by);

  Future<void> deleteArea(
    AreaId area, {
    Attribution by = const Attribution.user(),
  }) => _commit(AreaDeleted(area), by);

  Future<void> restoreArea(
    AreaId area, {
    Attribution by = const Attribution.user(),
  }) => _commit(AreaRestored(area), by);

  // --- projects ---

  Future<ProjectId> createProject({
    required String title,
    String notes = '',
    AreaId? area,
    TaskWhen when = TaskWhen.none,
    CalendarDate? deadline,
    List<TagId> tags = const [],
    DateTime? createdAt,
    ExternalRef? external,
    Attribution by = const Attribution.user(),
  }) async => (await _commit(
    ProjectCreated(
      title: title,
      notes: notes,
      area: area,
      when: when,
      deadline: deadline,
      tags: tags,
      createdAt: createdAt,
      external: external,
    ),
    by,
  )).id;

  Future<void> editProject(
    ProjectId project, {
    Patch<String>? title,
    Patch<String>? notes,
    Patch<AreaId?>? area,
    Patch<TaskWhen>? when,
    Patch<CalendarDate?>? deadline,
    Patch<List<TagId>>? tags,
    Attribution by = const Attribution.user(),
  }) => _commit(
    ProjectEdited(
      project,
      title: title,
      notes: notes,
      area: area,
      when: when,
      deadline: deadline,
      tags: tags,
    ),
    by,
  );

  Future<void> deleteProject(
    ProjectId project, {
    Attribution by = const Attribution.user(),
  }) => _commit(ProjectDeleted(project), by);

  Future<void> restoreProject(
    ProjectId project, {
    Attribution by = const Attribution.user(),
  }) => _commit(ProjectRestored(project), by);

  // --- headings ---

  Future<HeadingId> createHeading({
    required ProjectId project,
    required String title,
    DateTime? createdAt,
    ExternalRef? external,
    Attribution by = const Attribution.user(),
  }) async => (await _commit(
    HeadingCreated(
      project: project,
      title: title,
      createdAt: createdAt,
      external: external,
    ),
    by,
  )).id;

  Future<void> editHeading(
    HeadingId heading, {
    Patch<String>? title,
    Attribution by = const Attribution.user(),
  }) => _commit(HeadingEdited(heading, title: title), by);

  Future<void> deleteHeading(
    HeadingId heading, {
    Attribution by = const Attribution.user(),
  }) => _commit(HeadingDeleted(heading), by);

  Future<void> restoreHeading(
    HeadingId heading, {
    Attribution by = const Attribution.user(),
  }) => _commit(HeadingRestored(heading), by);

  // --- tags ---

  Future<TagId> createTag({
    required String title,
    TagId? parent,
    DateTime? createdAt,
    ExternalRef? external,
    Attribution by = const Attribution.user(),
  }) async => (await _commit(
    TagCreated(
      title: title,
      parent: parent,
      createdAt: createdAt,
      external: external,
    ),
    by,
  )).id;

  Future<void> editTag(
    TagId tag, {
    Patch<String>? title,
    Patch<TagId?>? parent,
    Attribution by = const Attribution.user(),
  }) => _commit(TagEdited(tag, title: title, parent: parent), by);

  Future<void> deleteTag(
    TagId tag, {
    Attribution by = const Attribution.user(),
  }) => _commit(TagDeleted(tag), by);

  Future<void> restoreTag(
    TagId tag, {
    Attribution by = const Attribution.user(),
  }) => _commit(TagRestored(tag), by);
}
