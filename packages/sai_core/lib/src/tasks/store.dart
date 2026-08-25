import 'dart:async';

import '../archive/archive.dart';
import '../archive/blobref.dart';
import '../archive/event.dart';
import 'capture.dart';
import 'date.dart';
import 'events.dart';
import 'lists.dart';
import 'model.dart';
import 'projection.dart';
import 'undo.dart';

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
  ///
  /// A torn tail — bytes a crashed write left after the last newline —
  /// never became an event, so it is read past, not failed on: the store
  /// opens on every event before it (appends will still refuse until the
  /// documented repair).
  static Future<TaskStore> open(
    Archive archive, {
    required String source,
  }) async {
    final events = await _readEvents(archive);
    return TaskStore._(archive, source, TaskProjection.replay(events));
  }

  /// Reads the whole log, tolerating a torn tail. A tear can also be the
  /// transient shadow of an in-flight append (reads are lock-free), so one
  /// re-read separates the two; a tear that persists is a crash trace and
  /// the events before it are the whole log.
  static Future<List<StoredEvent>> _readEvents(Archive archive) async {
    for (var attempt = 0; ; attempt++) {
      final events = <StoredEvent>[];
      try {
        await for (final stored in archive.events()) {
          events.add(stored);
        }
        return events;
      } on TornTailError {
        if (attempt > 0) return events;
      }
    }
  }

  final Archive _archive;

  /// The `source` written on every event this store appends.
  final String source;

  TaskProjection _projection;

  /// Synchronous on purpose: by the time a command's future completes,
  /// every listener — the riverpod layer included — has the new projection.
  final _changes = StreamController<TaskProjection>.broadcast(sync: true);

  /// Serializes commands and reloads: both replace [_projection] across
  /// awaits, and an interleaving could silently drop a durably appended
  /// event from the in-memory state.
  Future<void> _queue = Future<void>.value();

  var _disposed = false;

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// The current state. Replaced (never mutated) as commands apply.
  TaskProjection get projection => _projection;

  /// The projection after each command this store commits.
  Stream<TaskProjection> get changes => _changes.stream;

  /// Whether the changes stream currently has a subscriber. Lifecycle tests
  /// use this to prove an asynchronously opened store was never exposed.
  bool get hasChangeListeners => _changes.hasListener;

  /// Rebuilds the projection from the log — how appends made by another
  /// process (or another store) become visible. Serialized with commands.
  Future<void> reload() => _serialized(() async {
    _checkOpen();
    final events = await _readEvents(_archive);
    // The projection has seen exactly eventCount lines (its own commits
    // included), so what follows them is another writer's work; a system
    // task mutation among it is the same barrier a local one is.
    final unseen = events.skip(_projection.eventCount);
    if (unseen.any(_isSystemTaskMutation)) _undoStack.clear();
    _projection = TaskProjection.replay(events);
    _notify();
  });

  static bool _isSystemTaskMutation(StoredEvent stored) =>
      stored.event.actor == Actor.system &&
      TaskEventTypes.all.contains(stored.event.type);

  /// Closes the [changes] stream and refuses further commands. The archive
  /// is not touched — its owner closes it.
  void dispose() {
    _disposed = true;
    _changes.close();
  }

  void _checkOpen() {
    if (_disposed) {
      throw StateError('this TaskStore is disposed; open a new one');
    }
  }

  void _notify() {
    if (!_disposed) {
      _changes.add(_projection);
    }
  }

  /// How many mutations a session keeps undoable; the oldest entry goes
  /// first once the stack is full.
  static const undoLimit = 100;

  /// One entry per committed user or assistant command, newest last: the
  /// event that reverses it, and the id of the line it would reverse.
  /// Bounded to [undoLimit]. Session-local — the stack dies with the
  /// process and survives [reload] (entries name entities by id; a stale
  /// inverse is refused by validation, not by forgetting it) — except
  /// across a **system** task mutation: one committed here, or one
  /// another writer appended and a reload discovered, clears the stack
  /// and records nothing, so an import (#18) neither leaves thousands of
  /// entries nor lets an older inverse cross imported state.
  final _undoStack = <({TaskEvent inverse, BlobRef undone})>[];

  /// Whether [undo] has a mutation to reverse.
  bool get canUndo => _undoStack.isNotEmpty;

  /// How many mutations this session can unwind, newest first.
  int get undoDepth => _undoStack.length;

  /// Reverses the most recent not-yet-undone mutation of this session by
  /// appending its inverse event — undo is a new event, never a rewrite.
  /// Returns the appended event, or null when there is nothing to undo.
  /// Undo records no inverse of its own: there is no redo, and repeated
  /// calls unwind the session in reverse order.
  ///
  /// The inverse carries [by] with the reversed event's id added to its
  /// refs. A refused inverse (the reducer no longer accepts it after a
  /// concurrent change) throws and keeps its stack entry, so a [reload]
  /// and retry stay possible.
  Future<StoredEvent?> undo({Attribution by = const Attribution.user()}) =>
      _serialized(() async {
        _checkOpen();
        if (_undoStack.isEmpty) return null;
        // Pop first, so the commit's own notification already shows the
        // shrunk stack to synchronous listeners; a refused inverse never
        // notifies, so pushing the entry back is invisible.
        final entry = _undoStack.removeLast();
        final attribution = entry.inverse.refs.contains(entry.undone)
            ? by
            : by.withRefs([entry.undone]);
        try {
          return await _apply(entry.inverse, attribution, record: false);
        } catch (_) {
          _undoStack.add(entry);
          rethrow;
        }
      });

  /// Validate → append → apply → notify, serialized with [reload].
  /// Validation applies the event to the current projection under a
  /// tentative seal, so a command the reducer would refuse — and a command
  /// against a disposed store — never reaches the log.
  Future<StoredEvent> _commit(TaskEvent event, Attribution by) =>
      _serialized(() async {
        _checkOpen();
        return _apply(event, by, record: true);
      });

  /// Builds a command from the projection inside the serialized lane. Used
  /// by reorder commands whose event must repeat the task's current group.
  Future<StoredEvent> _commitFrom(
    TaskEvent Function(TaskProjection) build,
    Attribution by,
  ) => _serialized(() async {
    _checkOpen();
    return _apply(build(_projection), by, record: true);
  });

  /// The unserialized commit body; [undo] and [_commit] wrap it in
  /// [_serialized] themselves (nesting would deadlock on [_queue]).
  /// With [record], pushes the committed event's inverse — computed
  /// against the projection it was validated on — onto the undo stack;
  /// a system attribution is the undo barrier instead, whatever [record]
  /// says (an undo issued as the system clears the rest of the stack).
  Future<StoredEvent> _apply(
    TaskEvent event,
    Attribution by, {
    required bool record,
  }) async {
    final before = _projection;
    final draft = event.toDraft(source: source, by: by);
    late final TaskProjection next;
    final stored = await _archive.append(
      draft,
      validate: (stored) {
        next = before.apply(stored);
      },
    );
    _projection = next;
    try {
      if (by.actor == Actor.system) {
        _undoStack.clear();
      } else if (record) {
        _undoStack.add((
          inverse: invertEvent(event, before, created: stored.id),
          undone: stored.id,
        ));
        if (_undoStack.length > undoLimit) _undoStack.removeAt(0);
      }
    } finally {
      // The append is durable and applied; listeners are told even if
      // recording the inverse ever throws.
      _notify();
    }
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
    Patch<TaskId?>? after,
    Attribution by = const Attribution.user(),
  }) => _commit(
    TaskMoved(
      task,
      project: project,
      area: area,
      heading: heading,
      after: after,
    ),
    by,
  );

  /// Repositions [task] inside its current Inbox/area/project/heading group.
  Future<void> reorderTask(
    TaskId task, {
    required TaskId? after,
    Attribution by = const Attribution.user(),
  }) => _commitFrom((projection) {
    final current = projection.task(task);
    if (current == null) {
      // The tentative reducer turns this into the normal projection error;
      // keeping event construction total avoids a separate validation path.
      return TaskMoved(task, after: Patch(after));
    }
    return TaskMoved(
      task,
      project: current.project,
      area: current.area,
      heading: current.heading,
      after: Patch(after),
    );
  }, by);

  /// Repositions [task] in Today's independent manual order.
  Future<void> reorderToday(
    TaskId task, {
    required TaskId? after,
    Attribution by = const Attribution.user(),
  }) => _commit(TaskReordered(task, list: TaskList.today, after: after), by);

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

  /// Creates the Inbox task [line] describes — see [parseQuickCapture]
  /// for the grammar — and returns its id, or null when [line] is blank,
  /// in which case nothing is appended. One line, one `task.create`
  /// event. [today] anchors the `@today`/`@tomorrow` tokens; the store
  /// has no clock of its own.
  Future<TaskId?> quickCapture(
    String line, {
    required CalendarDate today,
    Attribution by = const Attribution.user(),
  }) async {
    final capture = parseQuickCapture(line, today: today);
    if (capture == null) return null;
    return createTask(
      title: capture.title,
      when: capture.when,
      deadline: capture.deadline,
      by: by,
    );
  }

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
