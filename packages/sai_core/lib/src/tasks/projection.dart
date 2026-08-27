import '../archive/archive.dart';
import '../archive/blobref.dart';
import 'codec.dart';
import 'date.dart';
import 'events.dart';
import 'lists.dart';
import 'model.dart';
import 'undo_state.dart';

/// A task-domain event that cannot be applied: its subject is unknown, of
/// the wrong kind, or violates a placement rule. Only sai writes task
/// events, so this means a bug or a hand-edited log — loud, never repaired.
final class TaskProjectionError implements Exception {
  const TaskProjectionError({required this.eventId, required this.reason});

  /// The id of the event that could not be applied.
  final BlobRef eventId;

  final String reason;

  @override
  String toString() => 'TaskProjectionError: $reason (event $eventId)';
}

/// The current state of the task domain: a disposable, in-memory projection
/// of the archive (ADR 0004, amended by #17 — the SQLite medium is
/// deferred). Rebuild it any time with [replay]; advance it one event at a
/// time with [apply]. Both run the same reducer.
///
/// Events outside the task family are counted but change nothing. A
/// malformed family payload throws [FormatException]; an unappliable one
/// throws [TaskProjectionError].
final class TaskProjection implements UndoState {
  TaskProjection._({
    required Map<TaskId, Task> tasks,
    required Map<ProjectId, Project> projects,
    required Map<HeadingId, Heading> headings,
    required Map<AreaId, Area> areas,
    required Map<TagId, Tag> tags,
    required Map<String, BlobRef> externals,
    required List<TaskId> structuralOrder,
    required List<TaskId> todayOrder,
    required List<AreaId> areaOrder,
    required List<ProjectId> projectOrder,
    required List<HeadingId> headingOrder,
    required this.lastEventId,
    required this.eventCount,
  }) : tasks = Map.unmodifiable(tasks),
       projects = Map.unmodifiable(projects),
       headings = Map.unmodifiable(headings),
       areas = Map.unmodifiable(areas),
       tags = Map.unmodifiable(tags),
       _externals = Map.unmodifiable(externals),
       structuralOrder = List.unmodifiable(structuralOrder),
       todayOrder = List.unmodifiable(todayOrder),
       areaOrder = List.unmodifiable(areaOrder),
       projectOrder = List.unmodifiable(projectOrder),
       headingOrder = List.unmodifiable(headingOrder);

  static final TaskProjection empty = TaskProjection._(
    tasks: const {},
    projects: const {},
    headings: const {},
    areas: const {},
    tags: const {},
    externals: const {},
    structuralOrder: const [],
    todayOrder: const [],
    areaOrder: const [],
    projectOrder: const [],
    headingOrder: const [],
    lastEventId: null,
    eventCount: 0,
  );

  /// Rebuilds the projection from [events], oldest first — the whole
  /// archive, or any prefix of it.
  static TaskProjection replay(Iterable<StoredEvent> events) {
    final builder = _Builder.from(empty);
    for (final stored in events) {
      builder.apply(stored);
    }
    return builder.build();
  }

  @override
  final Map<TaskId, Task> tasks;
  @override
  final Map<ProjectId, Project> projects;
  @override
  final Map<HeadingId, Heading> headings;
  @override
  final Map<AreaId, Area> areas;
  @override
  final Map<TagId, Tag> tags;
  final Map<String, BlobRef> _externals;

  /// Replayable task order for Inbox and placement/container groups.
  final List<TaskId> structuralOrder;

  /// Replayable manual order used only by Today.
  final List<TaskId> todayOrder;

  /// Replayable manual order of the areas — the sidebar's (#74).
  final List<AreaId> areaOrder;

  /// Replayable manual order of every project, one sequence grouped at
  /// read time by [groupOf] — as [structuralOrder] is grouped by placement.
  final List<ProjectId> projectOrder;

  /// Replayable manual order of every heading, grouped by project.
  final List<HeadingId> headingOrder;

  /// The id of the last event applied (task-domain or not), or null on
  /// [empty] — where a catch-up resumes from.
  final BlobRef? lastEventId;

  /// How many events this projection has seen, task-domain or not.
  final int eventCount;

  /// Applies one event and returns the advanced projection; the receiver is
  /// untouched.
  TaskProjection apply(StoredEvent stored) =>
      (_Builder.from(this)..apply(stored)).build();

  Task? task(TaskId id) => tasks[id];

  /// The task created by the import identified as [system]/[id], if any.
  Task? byExternal(String system, String id) {
    final ref = _externals['$system:$id'];
    return ref == null ? null : tasks[ref];
  }

  /// The entity id minted for the import identified as [system]/[id] —
  /// task or container. What a re-run of an importer dedupes against.
  BlobRef? idByExternal(String system, String id) => _externals['$system:$id'];

  /// The tasks of [list] as of [today] — the view unions of [listsOf], so a
  /// filed Today task also answers for Anytime and a future deadline
  /// surfaces in Upcoming — visible containers only, in the deterministic
  /// v0.1 order (manual ordering is #20). A task whose project, area or
  /// heading is deleted is hidden here — that is container visibility,
  /// deliberately outside the pure list rules.
  List<Task> list(TaskList list, {required CalendarDate today}) =>
      _sorted(list, [
        for (final task in tasks.values)
          if (_visible(task) && listsOf(task, today).contains(list)) task,
      ]);

  /// Deleted tasks, newest deletion first. The Trash is a query, not a list.
  List<Task> trash() {
    final deleted = [
      for (final task in tasks.values)
        if (task.deletedAt != null) task,
    ];
    deleted.sort((a, b) {
      final byWhen = b.deletedAt!.compareTo(a.deletedAt!);
      return byWhen != 0 ? byWhen : a.id.toString().compareTo(b.id.toString());
    });
    return List.unmodifiable(deleted);
  }

  /// Open, undeleted tasks placed in [id] (directly or under one of its
  /// headings), visible containers only, in structural order. With
  /// [archived] the container's own archived state is overlooked, so an
  /// archived project selected in the sidebar still shows its tasks.
  List<Task> inProject(ProjectId id, {bool archived = false}) =>
      _placed((t) => t.project == id, archived: archived);

  /// Open, undeleted tasks placed directly in area [id], visible
  /// containers only.
  List<Task> inArea(AreaId id, {bool archived = false}) =>
      _placed((t) => t.area == id, archived: archived);

  /// Open, undeleted tasks under heading [id], visible containers only.
  List<Task> underHeading(HeadingId id, {bool archived = false}) =>
      _placed((t) => t.heading == id, archived: archived);

  /// Open, undeleted tasks carrying [tag], visible containers only, in
  /// structural order — the tag view Quick Find opens (#76). Tasks parked
  /// in an archived container stay out unless [archived] says otherwise.
  List<Task> withTag(TagId tag, {bool archived = false}) =>
      _placed((t) => t.tags.contains(tag), archived: archived);

  List<Task> _placed(bool Function(Task) where, {required bool archived}) =>
      _ordered(structuralOrder, [
        for (final task in tasks.values)
          if (task.deletedAt == null &&
              task.status == TaskStatus.open &&
              _visible(task, archived: archived) &&
              where(task))
            task,
      ]);

  /// Whether [task]'s containers show it: none deleted, and — unless the
  /// caller is looking at an [archived] container on purpose — none
  /// archived.
  bool _visible(Task task, {bool archived = false}) {
    if (task.project case final id?) {
      if (_hidden(
        projects[id]?.deletedAt,
        projects[id]?.archivedAt,
        archived,
      )) {
        return false;
      }
    }
    if (task.area case final id?) {
      if (_hidden(areas[id]?.deletedAt, areas[id]?.archivedAt, archived)) {
        return false;
      }
    }
    if (task.heading case final id?) {
      if (headings[id]?.deletedAt != null) return false;
    }
    return true;
  }

  static bool _hidden(
    DateTime? deletedAt,
    DateTime? archivedAt,
    bool archived,
  ) => deletedAt != null || (!archived && archivedAt != null);

  /// Live areas — neither deleted nor archived — in [areaOrder].
  List<Area> liveAreas() =>
      _areasWhere((a) => a.deletedAt == null && a.archivedAt == null);

  /// Archived, undeleted areas in [areaOrder] — what an Archive screen
  /// lists so a client can unarchive. A query, not a list, like the Trash.
  List<Area> archivedAreas() =>
      _areasWhere((a) => a.deletedAt == null && a.archivedAt != null);

  /// Live projects in [projectOrder]; group them with [groupOf].
  List<Project> liveProjects() =>
      _projectsWhere((p) => p.deletedAt == null && p.archivedAt == null);

  /// Archived, undeleted projects in [projectOrder].
  List<Project> archivedProjects() =>
      _projectsWhere((p) => p.deletedAt == null && p.archivedAt != null);

  /// The live headings of [project], in [headingOrder].
  List<Heading> headingsOf(ProjectId project) => List.unmodifiable([
    for (final id in headingOrder)
      if (headings[id] case final heading?
          when heading.project == project && heading.deletedAt == null)
        heading,
  ]);

  /// The area a project is *listed* under: its own area when that area is
  /// live, else null — a project whose area is deleted or archived lists
  /// standalone rather than hiding. The reducer keeps its own copy.
  AreaId? groupOf(Project project) {
    final area = project.area;
    if (area == null) return null;
    final owner = areas[area];
    if (owner == null || owner.deletedAt != null || owner.archivedAt != null) {
      return null;
    }
    return area;
  }

  List<Area> _areasWhere(bool Function(Area) keep) => List.unmodifiable([
    for (final id in areaOrder)
      if (areas[id] case final area? when keep(area)) area,
  ]);

  List<Project> _projectsWhere(bool Function(Project) keep) =>
      List.unmodifiable([
        for (final id in projectOrder)
          if (projects[id] case final project? when keep(project)) project,
      ]);

  List<Task> _sorted(TaskList? list, List<Task> items) {
    if (list == TaskList.logbook) {
      items.sort((a, b) {
        final aDone = a.cancelledAt ?? a.completedAt!;
        final bDone = b.cancelledAt ?? b.completedAt!;
        final byWhen = bDone.compareTo(aDone);
        return byWhen != 0
            ? byWhen
            : a.id.toString().compareTo(b.id.toString());
      });
    } else if (list == TaskList.upcoming) {
      items.sort(_openOrder);
    } else {
      return _ordered(
        list == TaskList.today ? todayOrder : structuralOrder,
        items,
      );
    }
    return List.unmodifiable(items);
  }

  List<Task> _ordered(List<TaskId> order, List<Task> items) {
    final byId = {for (final task in items) task.id: task};
    return List.unmodifiable([
      for (final id in order) ?byId.remove(id),
      ...byId.values,
    ]);
  }

  /// The prior live sibling in [task]'s structural group, for an inverse
  /// move. Null means the task was first.
  @override
  TaskId? structuralPredecessor(TaskId task) {
    final target = tasks[task];
    if (target == null) return null;
    TaskId? prior;
    for (final id in structuralOrder) {
      if (id == task) return prior;
      final candidate = tasks[id];
      if (candidate != null &&
          candidate.deletedAt == null &&
          candidate.status == TaskStatus.open &&
          _visible(candidate) &&
          _samePlacement(candidate, target)) {
        prior = id;
      }
    }
    return prior;
  }

  /// The prior task in Today's independent sequence, for exact undo. Unlike
  /// structural anchors, Today anchors need not currently be visible: the
  /// sequence deliberately retains filtered tasks.
  @override
  TaskId? todayPredecessor(TaskId task) {
    final index = todayOrder.indexOf(task);
    return index <= 0 ? null : todayOrder[index - 1];
  }

  @override
  AreaId? areaPredecessor(AreaId area) {
    if (!areas.containsKey(area)) return null;
    AreaId? prior;
    for (final id in areaOrder) {
      if (id == area) return prior;
      final candidate = areas[id];
      if (candidate != null &&
          candidate.deletedAt == null &&
          candidate.archivedAt == null) {
        prior = id;
      }
    }
    return prior;
  }

  @override
  ProjectId? projectPredecessor(ProjectId project) {
    final target = projects[project];
    if (target == null) return null;
    final group = groupOf(target);
    ProjectId? prior;
    for (final id in projectOrder) {
      if (id == project) return prior;
      final candidate = projects[id];
      if (candidate != null &&
          candidate.deletedAt == null &&
          candidate.archivedAt == null &&
          groupOf(candidate) == group) {
        prior = id;
      }
    }
    return prior;
  }

  @override
  HeadingId? headingPredecessor(HeadingId heading) {
    final target = headings[heading];
    if (target == null) return null;
    HeadingId? prior;
    for (final id in headingOrder) {
      if (id == heading) return prior;
      final candidate = headings[id];
      if (candidate != null &&
          candidate.deletedAt == null &&
          candidate.project == target.project) {
        prior = id;
      }
    }
    return prior;
  }

  static int _openOrder(Task a, Task b) {
    final aWhen = a.when is TaskWhenDate ? (a.when as TaskWhenDate).date : null;
    final bWhen = b.when is TaskWhenDate ? (b.when as TaskWhenDate).date : null;
    final byWhen = _nullsLast(aWhen, bWhen);
    if (byWhen != 0) return byWhen;
    final byDeadline = _nullsLast(a.deadline, b.deadline);
    if (byDeadline != 0) return byDeadline;
    final byCreated = a.createdAt.compareTo(b.createdAt);
    if (byCreated != 0) return byCreated;
    return a.id.toString().compareTo(b.id.toString());
  }

  static int _nullsLast(CalendarDate? a, CalendarDate? b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return a.compareTo(b);
  }

  /// A plain-JSON dump of the whole projection — for tests, debugging and
  /// an importer's dry-run diff. Not a wire contract.
  Map<String, Object?> toJson() => {
    'last_event': lastEventId?.toString(),
    'count': eventCount,
    'tasks': [for (final t in _byId(tasks)) t.toJson()],
    'projects': [for (final p in _byId(projects)) p.toJson()],
    'headings': [for (final h in _byId(headings)) h.toJson()],
    'areas': [for (final a in _byId(areas)) a.toJson()],
    'tags': [for (final t in _byId(tags)) t.toJson()],
    'structural_order': [for (final id in structuralOrder) id.toString()],
    'today_order': [for (final id in todayOrder) id.toString()],
    'area_order': [for (final id in areaOrder) id.toString()],
    'project_order': [for (final id in projectOrder) id.toString()],
    'heading_order': [for (final id in headingOrder) id.toString()],
    'externals': {
      for (final key in _externals.keys.toList()..sort())
        key: _externals[key]!.toString(),
    },
  };

  static List<V> _byId<V>(Map<BlobRef, V> map) {
    final keys = map.keys.toList()
      ..sort((a, b) => a.toString().compareTo(b.toString()));
    return [for (final key in keys) map[key] as V];
  }

  factory TaskProjection.fromJson(Object? json) {
    final map = requireObject(json, 'projection');
    rejectUnknownKeys(map, const {
      'last_event',
      'count',
      'tasks',
      'projects',
      'headings',
      'areas',
      'tags',
      'structural_order',
      'today_order',
      'area_order',
      'project_order',
      'heading_order',
      'externals',
    }, where: 'projection');
    final count = map['count'];
    if (count is! int || count < 0) {
      throw const FormatException(
        'projection.count must be a non-negative integer',
      );
    }
    final externalsJson = requireObject(map['externals'], 'externals');
    final tasks = <TaskId, Task>{
      for (final json in jsonList(map, 'tasks', where: 'projection'))
        Task.fromJson(json).id: Task.fromJson(json),
    };
    final projects = <ProjectId, Project>{
      for (final json in jsonList(map, 'projects', where: 'projection'))
        Project.fromJson(json).id: Project.fromJson(json),
    };
    final headings = <HeadingId, Heading>{
      for (final json in jsonList(map, 'headings', where: 'projection'))
        Heading.fromJson(json).id: Heading.fromJson(json),
    };
    final areas = <AreaId, Area>{
      for (final json in jsonList(map, 'areas', where: 'projection'))
        Area.fromJson(json).id: Area.fromJson(json),
    };
    return TaskProjection._(
      tasks: tasks,
      projects: projects,
      headings: headings,
      areas: areas,
      tags: {
        for (final json in jsonList(map, 'tags', where: 'projection'))
          Tag.fromJson(json).id: Tag.fromJson(json),
      },
      externals: {
        for (final entry in externalsJson.entries)
          entry.key: requireBlobRef(
            entry.value,
            where: 'projection.externals.${entry.key}',
          ),
      },
      structuralOrder: _decodeOrder(
        map['structural_order'],
        'projection.structural_order',
        tasks.keys,
        noun: 'task',
      ),
      todayOrder: _decodeOrder(
        map['today_order'],
        'projection.today_order',
        tasks.keys,
        noun: 'task',
      ),
      areaOrder: _decodeOrder(
        map['area_order'],
        'projection.area_order',
        areas.keys,
        noun: 'area',
      ),
      projectOrder: _decodeOrder(
        map['project_order'],
        'projection.project_order',
        projects.keys,
        noun: 'project',
      ),
      headingOrder: _decodeOrder(
        map['heading_order'],
        'projection.heading_order',
        headings.keys,
        noun: 'heading',
      ),
      lastEventId: nullableBlobRef(
        map['last_event'],
        where: 'projection.last_event',
      ),
      eventCount: count,
    );
  }
}

List<BlobRef> _decodeOrder(
  Object? json,
  String where,
  Iterable<BlobRef> ids, {
  required String noun,
}) {
  if (json is! List<Object?>) {
    throw FormatException('$where must be an array');
  }
  final order = <BlobRef>[];
  try {
    for (final value in json) {
      if (value is! String) throw FormatException('$where entries are ids');
      order.add(BlobRef.parse(value));
    }
  } on ArgumentError catch (error) {
    throw FormatException('$where contains an invalid id: $error');
  }
  if (order.toSet().length != order.length ||
      order.toSet().difference(ids.toSet()).isNotEmpty ||
      ids.toSet().difference(order.toSet()).isNotEmpty) {
    throw FormatException('$where must contain every $noun id exactly once');
  }
  return order;
}

bool _samePlacement(Task a, Task b) =>
    a.project == b.project && a.area == b.area && a.heading == b.heading;

/// The reducer's working state: plain mutable maps, so a bulk [replay]
/// stays O(events) instead of copying every map per event.
final class _Builder {
  _Builder.from(TaskProjection base)
    : _tasks = Map.of(base.tasks),
      _projects = Map.of(base.projects),
      _headings = Map.of(base.headings),
      _areas = Map.of(base.areas),
      _tags = Map.of(base.tags),
      _externals = Map.of(base._externals),
      _structuralOrder = List.of(base.structuralOrder),
      _todayOrder = List.of(base.todayOrder),
      _areaOrder = List.of(base.areaOrder),
      _projectOrder = List.of(base.projectOrder),
      _headingOrder = List.of(base.headingOrder),
      _lastEventId = base.lastEventId,
      _eventCount = base.eventCount;

  final Map<TaskId, Task> _tasks;
  final Map<ProjectId, Project> _projects;
  final Map<HeadingId, Heading> _headings;
  final Map<AreaId, Area> _areas;
  final Map<TagId, Tag> _tags;
  final Map<String, BlobRef> _externals;
  final List<TaskId> _structuralOrder;
  final List<TaskId> _todayOrder;
  final List<AreaId> _areaOrder;
  final List<ProjectId> _projectOrder;
  final List<HeadingId> _headingOrder;
  BlobRef? _lastEventId;
  int _eventCount;

  TaskProjection build() => TaskProjection._(
    tasks: _tasks,
    projects: _projects,
    headings: _headings,
    areas: _areas,
    tags: _tags,
    externals: _externals,
    structuralOrder: _structuralOrder,
    todayOrder: _todayOrder,
    areaOrder: _areaOrder,
    projectOrder: _projectOrder,
    headingOrder: _headingOrder,
    lastEventId: _lastEventId,
    eventCount: _eventCount,
  );

  void apply(StoredEvent stored) {
    final TaskEvent? event;
    try {
      event = decodeTaskEvent(stored.event);
    } on FormatException catch (e) {
      throw FormatException('event ${stored.id}: ${e.message}');
    }
    if (event != null) {
      _reduce(stored, event);
    }
    _lastEventId = stored.id;
    _eventCount++;
  }

  Never _refuse(StoredEvent stored, String reason) =>
      throw TaskProjectionError(eventId: stored.id, reason: reason);

  void _reduce(StoredEvent stored, TaskEvent event) {
    final ts = stored.event.ts;
    switch (event) {
      case TaskCreated():
        _checkPlacement(
          stored,
          project: event.project,
          area: event.area,
          heading: event.heading,
        );
        _checkTags(stored, event.tags);
        _tasks[stored.id] = Task(
          id: stored.id,
          title: event.title,
          notes: event.notes,
          when: event.when,
          deadline: event.deadline,
          project: event.project,
          area: event.area,
          heading: event.heading,
          tags: event.tags,
          checklist: event.checklist,
          createdAt: event.createdAt ?? ts,
          modifiedAt: ts,
          external: event.external,
        );
        _structuralOrder.add(stored.id);
        _todayOrder.add(stored.id);
        _index(stored, event.external);
      case TaskEdited():
        if (event.tags != null) _checkTags(stored, event.tags!.value);
        _tasks[event.task] = _task(stored, event.task).copyWith(
          title: event.title,
          notes: event.notes,
          when: event.when,
          deadline: event.deadline,
          tags: event.tags,
          modifiedAt: Patch(ts),
        );
      case TaskMoved():
        final task = _task(stored, event.task);
        _checkPlacement(
          stored,
          project: event.project,
          area: event.area,
          heading: event.heading,
          staying: task,
        );
        if (event.after case Patch(value: final after)) {
          _checkStructuralAnchor(
            stored,
            task: event.task,
            after: after,
            project: event.project,
            area: event.area,
            heading: event.heading,
          );
        }
        _tasks[event.task] = task.copyWith(
          project: Patch(event.project),
          area: Patch(event.area),
          heading: Patch(event.heading),
          modifiedAt: Patch(ts),
        );
        _positionStructural(event);
      case TaskReordered():
        final task = _task(stored, event.task);
        if (!_isLive(task)) {
          _refuse(stored, 'the Today task ${event.task} is not live');
        }
        final after = event.after;
        if (after == event.task) {
          _refuse(stored, 'a task cannot be ordered after itself');
        }
        if (after != null) {
          _task(stored, after);
        }
        _position(_todayOrder, event.task, after: after, first: after == null);
      case TaskCompleted():
        _tasks[event.task] = _task(stored, event.task).copyWith(
          completedAt: Patch(event.at ?? ts),
          cancelledAt: const Patch(null),
          modifiedAt: Patch(ts),
        );
      case TaskCancelled():
        _tasks[event.task] = _task(stored, event.task).copyWith(
          completedAt: const Patch(null),
          cancelledAt: Patch(event.at ?? ts),
          modifiedAt: Patch(ts),
        );
      case TaskReopened():
        _tasks[event.task] = _task(stored, event.task).copyWith(
          completedAt: const Patch(null),
          cancelledAt: const Patch(null),
          modifiedAt: Patch(ts),
        );
      case TaskDeleted():
        _tasks[event.task] = _task(
          stored,
          event.task,
        ).copyWith(deletedAt: Patch(ts), modifiedAt: Patch(ts));
      case TaskRestored():
        _tasks[event.task] = _task(
          stored,
          event.task,
        ).copyWith(deletedAt: const Patch(null), modifiedAt: Patch(ts));
      case TaskChecklistSet():
        _tasks[event.task] = _task(
          stored,
          event.task,
        ).copyWith(checklist: Patch(event.items), modifiedAt: Patch(ts));
      case AreaCreated():
        _areas[stored.id] = Area(
          id: stored.id,
          title: event.title,
          createdAt: event.createdAt ?? ts,
          modifiedAt: ts,
          external: event.external,
        );
        _areaOrder.add(stored.id);
        _index(stored, event.external);
      case AreaEdited():
        _areas[event.area] = _area(
          stored,
          event.area,
        ).copyWith(title: event.title, modifiedAt: Patch(ts));
      case AreaReordered():
        final area = _area(stored, event.area);
        if (!_isLiveArea(area)) {
          _refuse(stored, 'the area ${event.area} is not live');
        }
        _checkAreaAnchor(stored, area: event.area, after: event.after);
        _position(
          _areaOrder,
          event.area,
          after: event.after,
          first: event.after == null,
        );
      case AreaArchived():
        _areas[event.area] = _area(
          stored,
          event.area,
        ).copyWith(archivedAt: Patch(ts), modifiedAt: Patch(ts));
      case AreaUnarchived():
        _areas[event.area] = _area(
          stored,
          event.area,
        ).copyWith(archivedAt: const Patch(null), modifiedAt: Patch(ts));
      case AreaDeleted():
        _areas[event.area] = _area(
          stored,
          event.area,
        ).copyWith(deletedAt: Patch(ts), modifiedAt: Patch(ts));
      case AreaRestored():
        _areas[event.area] = _area(
          stored,
          event.area,
        ).copyWith(deletedAt: const Patch(null), modifiedAt: Patch(ts));
      case ProjectCreated():
        if (event.area != null) _livingArea(stored, event.area!);
        _checkTags(stored, event.tags);
        _projects[stored.id] = Project(
          id: stored.id,
          title: event.title,
          notes: event.notes,
          area: event.area,
          when: event.when,
          deadline: event.deadline,
          tags: event.tags,
          createdAt: event.createdAt ?? ts,
          modifiedAt: ts,
          external: event.external,
        );
        _projectOrder.add(stored.id);
        _index(stored, event.external);
      case ProjectEdited():
        if (event.area case Patch(value: final AreaId area)) {
          _livingArea(stored, area);
        }
        if (event.tags != null) _checkTags(stored, event.tags!.value);
        final current = _project(stored, event.project);
        _projects[event.project] = current.copyWith(
          title: event.title,
          notes: event.notes,
          area: event.area,
          when: event.when,
          deadline: event.deadline,
          tags: event.tags,
          modifiedAt: Patch(ts),
        );
        // A changed area is a group move: append to the end of the new
        // group, like a placement move without `after`. Rewriting the same
        // area leaves the order alone.
        if (event.area case Patch(value: final next)
            when next != current.area) {
          _positionProject(event.project, group: _groupOfArea(next));
        }
      case ProjectReordered():
        final project = _project(stored, event.project);
        if (!_isLiveProject(project)) {
          _refuse(stored, 'the project ${event.project} is not live');
        }
        _checkProjectAnchor(stored, project: event.project, after: event.after);
        _position(
          _projectOrder,
          event.project,
          after: event.after,
          first: event.after == null,
        );
      case ProjectArchived():
        _projects[event.project] = _project(
          stored,
          event.project,
        ).copyWith(archivedAt: Patch(ts), modifiedAt: Patch(ts));
      case ProjectUnarchived():
        _projects[event.project] = _project(
          stored,
          event.project,
        ).copyWith(archivedAt: const Patch(null), modifiedAt: Patch(ts));
      case ProjectDeleted():
        _projects[event.project] = _project(
          stored,
          event.project,
        ).copyWith(deletedAt: Patch(ts), modifiedAt: Patch(ts));
      case ProjectRestored():
        _projects[event.project] = _project(
          stored,
          event.project,
        ).copyWith(deletedAt: const Patch(null), modifiedAt: Patch(ts));
      case HeadingCreated():
        _livingProject(stored, event.project);
        _headings[stored.id] = Heading(
          id: stored.id,
          project: event.project,
          title: event.title,
          createdAt: event.createdAt ?? ts,
          modifiedAt: ts,
        );
        _headingOrder.add(stored.id);
        _index(stored, event.external);
      case HeadingEdited():
        _headings[event.heading] = _heading(
          stored,
          event.heading,
        ).copyWith(title: event.title, modifiedAt: Patch(ts));
      case HeadingReordered():
        final heading = _heading(stored, event.heading);
        if (heading.deletedAt != null) {
          _refuse(stored, 'the heading ${event.heading} is not live');
        }
        _checkHeadingAnchor(stored, heading: event.heading, after: event.after);
        _position(
          _headingOrder,
          event.heading,
          after: event.after,
          first: event.after == null,
        );
      case HeadingDeleted():
        _headings[event.heading] = _heading(
          stored,
          event.heading,
        ).copyWith(deletedAt: Patch(ts), modifiedAt: Patch(ts));
      case HeadingRestored():
        _headings[event.heading] = _heading(
          stored,
          event.heading,
        ).copyWith(deletedAt: const Patch(null), modifiedAt: Patch(ts));
      case TagCreated():
        if (event.parent != null) _livingTag(stored, event.parent!);
        _tags[stored.id] = Tag(
          id: stored.id,
          title: event.title,
          parent: event.parent,
          createdAt: event.createdAt ?? ts,
          modifiedAt: ts,
        );
        _index(stored, event.external);
      case TagEdited():
        if (event.parent case Patch(value: final TagId parent)) {
          _livingTag(stored, parent);
          _checkTagParent(stored, event.tag, parent);
        }
        _tags[event.tag] = _tag(stored, event.tag).copyWith(
          title: event.title,
          parent: event.parent,
          modifiedAt: Patch(ts),
        );
      case TagDeleted():
        _tags[event.tag] = _tag(
          stored,
          event.tag,
        ).copyWith(deletedAt: Patch(ts), modifiedAt: Patch(ts));
      case TagRestored():
        _tags[event.tag] = _tag(
          stored,
          event.tag,
        ).copyWith(deletedAt: const Patch(null), modifiedAt: Patch(ts));
    }
  }

  void _index(StoredEvent stored, ExternalRef? external) {
    if (external != null) {
      _externals[external.key] = stored.id;
    }
  }

  Task _task(StoredEvent stored, TaskId id) =>
      _tasks[id] ?? _refuse(stored, _describeMiss(id, 'task'));

  Project _project(StoredEvent stored, ProjectId id) =>
      _projects[id] ?? _refuse(stored, _describeMiss(id, 'project'));

  Heading _heading(StoredEvent stored, HeadingId id) =>
      _headings[id] ?? _refuse(stored, _describeMiss(id, 'heading'));

  Area _area(StoredEvent stored, AreaId id) =>
      _areas[id] ?? _refuse(stored, _describeMiss(id, 'area'));

  Tag _tag(StoredEvent stored, TagId id) =>
      _tags[id] ?? _refuse(stored, _describeMiss(id, 'tag'));

  /// [_project] plus a liveness check: a soft-deleted or archived
  /// container refuses new members — anything placed into it would vanish
  /// from every view.
  Project _livingProject(StoredEvent stored, ProjectId id) {
    final project = _project(stored, id);
    if (project.deletedAt != null) {
      _refuse(stored, 'project $id is deleted');
    }
    if (project.archivedAt != null) {
      _refuse(stored, 'project $id is archived');
    }
    return project;
  }

  Area _livingArea(StoredEvent stored, AreaId id) {
    final area = _area(stored, id);
    if (area.deletedAt != null) {
      _refuse(stored, 'area $id is deleted');
    }
    if (area.archivedAt != null) {
      _refuse(stored, 'area $id is archived');
    }
    return area;
  }

  static bool _isLiveArea(Area area) =>
      area.deletedAt == null && area.archivedAt == null;

  static bool _isLiveProject(Project project) =>
      project.deletedAt == null && project.archivedAt == null;

  /// The reducer's copy of [TaskProjection.groupOf].
  AreaId? _groupOfArea(AreaId? area) {
    if (area == null) return null;
    final owner = _areas[area];
    return owner == null || !_isLiveArea(owner) ? null : area;
  }

  void _checkAreaAnchor(
    StoredEvent stored, {
    required AreaId area,
    required AreaId? after,
  }) {
    if (after == null) return;
    if (after == area) {
      _refuse(stored, 'an area cannot be ordered after itself');
    }
    if (!_isLiveArea(_area(stored, after))) {
      _refuse(stored, 'the area anchor $after is not live');
    }
  }

  void _checkProjectAnchor(
    StoredEvent stored, {
    required ProjectId project,
    required ProjectId? after,
  }) {
    if (after == null) return;
    if (after == project) {
      _refuse(stored, 'a project cannot be ordered after itself');
    }
    final anchor = _project(stored, after);
    if (!_isLiveProject(anchor)) {
      _refuse(stored, 'the project anchor $after is not live');
    }
    if (_groupOfArea(anchor.area) != _groupOfArea(_projects[project]!.area)) {
      _refuse(stored, 'the project anchor $after is in another group');
    }
  }

  void _checkHeadingAnchor(
    StoredEvent stored, {
    required HeadingId heading,
    required HeadingId? after,
  }) {
    if (after == null) return;
    if (after == heading) {
      _refuse(stored, 'a heading cannot be ordered after itself');
    }
    final anchor = _heading(stored, after);
    if (anchor.deletedAt != null) {
      _refuse(stored, 'the heading anchor $after is not live');
    }
    if (anchor.project != _headings[heading]!.project) {
      _refuse(stored, 'the heading anchor $after is in another group');
    }
  }

  /// Appends [project] to the end of [group] — [_positionStructural]'s
  /// append branch with placement replaced by group.
  void _positionProject(ProjectId project, {required AreaId? group}) {
    _projectOrder.remove(project);
    var last = -1;
    for (var index = 0; index < _projectOrder.length; index++) {
      if (_groupOfArea(_projects[_projectOrder[index]]!.area) == group) {
        last = index;
      }
    }
    _projectOrder.insert(last < 0 ? _projectOrder.length : last + 1, project);
  }

  Heading _livingHeading(StoredEvent stored, HeadingId id) {
    final heading = _heading(stored, id);
    if (heading.deletedAt != null) {
      _refuse(stored, 'heading $id is deleted');
    }
    return heading;
  }

  Tag _livingTag(StoredEvent stored, TagId id) {
    final tag = _tag(stored, id);
    if (tag.deletedAt != null) {
      _refuse(stored, 'tag $id is deleted');
    }
    return tag;
  }

  /// Refuses a parent that is, or descends from, [tag] — the log is
  /// append-only, so a committed cycle could never be removed.
  void _checkTagParent(StoredEvent stored, TagId tag, TagId parent) {
    TagId? cursor = parent;
    while (cursor != null) {
      if (cursor == tag) {
        _refuse(stored, 'tag $parent would make $tag its own ancestor');
      }
      cursor = _tags[cursor]?.parent;
    }
  }

  String _describeMiss(BlobRef id, String wanted) {
    final actual = _tasks.containsKey(id)
        ? 'task'
        : _projects.containsKey(id)
        ? 'project'
        : _headings.containsKey(id)
        ? 'heading'
        : _areas.containsKey(id)
        ? 'area'
        : _tags.containsKey(id)
        ? 'tag'
        : null;
    return actual == null
        ? 'unknown $wanted: $id'
        : '$id is a $actual, not a $wanted';
  }

  void _checkStructuralAnchor(
    StoredEvent stored, {
    required TaskId task,
    required TaskId? after,
    required ProjectId? project,
    required AreaId? area,
    required HeadingId? heading,
  }) {
    if (after == null) return;
    if (after == task) {
      _refuse(stored, 'a task cannot be ordered after itself');
    }
    final anchor = _task(stored, after);
    if (!_isLive(anchor)) {
      _refuse(stored, 'the structural anchor $after is not live');
    }
    if (anchor.project != project ||
        anchor.area != area ||
        anchor.heading != heading) {
      _refuse(stored, 'the structural anchor $after is in another group');
    }
  }

  bool _isLive(Task task) {
    if (task.deletedAt != null || task.status != TaskStatus.open) return false;
    if (task.project case final project?) {
      if (_projects[project] case final p? when !_isLiveProject(p)) {
        return false;
      }
    }
    if (task.area case final area?) {
      if (_areas[area] case final a? when !_isLiveArea(a)) return false;
    }
    if (task.heading case final heading?) {
      if (_headings[heading]?.deletedAt != null) return false;
    }
    return true;
  }

  void _positionStructural(TaskMoved event) {
    _structuralOrder.remove(event.task);
    if (event.after case Patch(value: final after)) {
      if (after != null) {
        final index = _structuralOrder.indexOf(after);
        _structuralOrder.insert(index + 1, event.task);
        return;
      }
      final first = _structuralOrder.indexWhere(
        (id) => _hasPlacement(
          id,
          project: event.project,
          area: event.area,
          heading: event.heading,
        ),
      );
      _structuralOrder.insert(
        first < 0 ? _structuralOrder.length : first,
        event.task,
      );
      return;
    }

    var last = -1;
    for (var index = 0; index < _structuralOrder.length; index++) {
      if (_hasPlacement(
        _structuralOrder[index],
        project: event.project,
        area: event.area,
        heading: event.heading,
      )) {
        last = index;
      }
    }
    _structuralOrder.insert(
      last < 0 ? _structuralOrder.length : last + 1,
      event.task,
    );
  }

  bool _hasPlacement(
    TaskId id, {
    required ProjectId? project,
    required AreaId? area,
    required HeadingId? heading,
  }) {
    final task = _tasks[id]!;
    return task.project == project &&
        task.area == area &&
        task.heading == heading;
  }

  void _position(
    List<BlobRef> order,
    BlobRef task, {
    required BlobRef? after,
    required bool first,
  }) {
    order.remove(task);
    if (first) {
      order.insert(0, task);
      return;
    }
    order.insert(order.indexOf(after!) + 1, task);
  }

  /// Refuses a placement into a deleted or archived container. A task
  /// [staying] in the container it is already in (a heading change inside
  /// an archived project) is not a new member: the container's archived
  /// state is overlooked for it, its deletion is not.
  void _checkPlacement(
    StoredEvent stored, {
    required ProjectId? project,
    required AreaId? area,
    required HeadingId? heading,
    Task? staying,
  }) {
    if (project != null) {
      if (staying?.project == project) {
        if (_project(stored, project).deletedAt != null) {
          _refuse(stored, 'project $project is deleted');
        }
      } else {
        _livingProject(stored, project);
      }
    }
    if (area != null) {
      if (staying?.area == area) {
        if (_area(stored, area).deletedAt != null) {
          _refuse(stored, 'area $area is deleted');
        }
      } else {
        _livingArea(stored, area);
      }
    }
    if (heading != null) {
      final owner = _livingHeading(stored, heading).project;
      if (owner != project) {
        _refuse(stored, 'heading $heading belongs to project $owner');
      }
    }
  }

  void _checkTags(StoredEvent stored, List<TagId> tags) {
    for (final tag in tags) {
      _livingTag(stored, tag);
    }
  }
}
