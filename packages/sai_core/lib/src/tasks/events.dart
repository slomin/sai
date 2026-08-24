import '../archive/blobref.dart';
import '../archive/event.dart';
import 'codec.dart';
import 'date.dart';
import 'model.dart';

/// The task-domain event types. The registry lives in
/// `docs/archive/event-log-v0.md`; payload schemas in
/// `docs/tasks/task-model-v0.md`. A breaking payload change is a new type
/// name, never a rewrite.
abstract final class TaskEventTypes {
  static const taskCreate = 'task.create';
  static const taskEdit = 'task.edit';
  static const taskMove = 'task.move';
  static const taskComplete = 'task.complete';
  static const taskCancel = 'task.cancel';
  static const taskReopen = 'task.reopen';
  static const taskDelete = 'task.delete';
  static const taskRestore = 'task.restore';
  static const taskChecklist = 'task.checklist';
  static const areaCreate = 'area.create';
  static const areaEdit = 'area.edit';
  static const areaDelete = 'area.delete';
  static const areaRestore = 'area.restore';
  static const projectCreate = 'project.create';
  static const projectEdit = 'project.edit';
  static const projectDelete = 'project.delete';
  static const projectRestore = 'project.restore';
  static const headingCreate = 'heading.create';
  static const headingEdit = 'heading.edit';
  static const headingDelete = 'heading.delete';
  static const headingRestore = 'heading.restore';
  static const tagCreate = 'tag.create';
  static const tagEdit = 'tag.edit';
  static const tagDelete = 'tag.delete';
  static const tagRestore = 'tag.restore';

  static const all = <String>[
    taskCreate,
    taskEdit,
    taskMove,
    taskComplete,
    taskCancel,
    taskReopen,
    taskDelete,
    taskRestore,
    taskChecklist,
    areaCreate,
    areaEdit,
    areaDelete,
    areaRestore,
    projectCreate,
    projectEdit,
    projectDelete,
    projectRestore,
    headingCreate,
    headingEdit,
    headingDelete,
    headingRestore,
    tagCreate,
    tagEdit,
    tagDelete,
    tagRestore,
  ];
}

/// Who a task mutation speaks for. `user` is the person acting directly;
/// `system` is machinery like the Things import (#18); `assistant` is a
/// model-made change (#35) and must carry the model that made it —
/// [Event.seal] enforces that one layer down. Extra [refs] point at earlier
/// events this mutation stems from, e.g. the proposal it applies.
final class Attribution {
  const Attribution.user({this.refs = const []})
    : actor = Actor.user,
      model = null;

  const Attribution.system({this.refs = const []})
    : actor = Actor.system,
      model = null;

  const Attribution.assistant(ModelRef this.model, {this.refs = const []})
    : actor = Actor.assistant;

  final Actor actor;
  final ModelRef? model;
  final List<BlobRef> refs;
}

/// One task-domain mutation, decoupled from its place in the log: the same
/// value is built by a store command (then sealed via [toDraft]) and
/// recovered from a stored line (via [decodeTaskEvent]).
///
/// Only the payload is normative for the reducer. The envelope's `refs`
/// repeats the subject for generic provenance tooling — never read it back.
sealed class TaskEvent {
  const TaskEvent();

  /// The registry type name.
  String get type;

  /// The entity this event mutates; null for `*.create` (the sealed event's
  /// own id becomes the entity id).
  BlobRef? get subject;

  /// Ids this event points at in the envelope: the subject, plus the
  /// destination containers for a move.
  List<BlobRef> get refs => [?subject];

  /// The payload exactly as written to the line.
  Map<String, Object?> toPayload();

  /// Wraps this mutation for [Archive.append].
  EventDraft toDraft({
    required String source,
    Attribution by = const Attribution.user(),
  }) {
    final allRefs = [...refs, ...by.refs];
    return EventDraft(
      type: type,
      actor: by.actor,
      source: source,
      payload: toPayload(),
      model: by.model,
      refs: allRefs.isEmpty ? null : allRefs,
    );
  }
}

void _checkPlacement({
  required BlobRef? project,
  required BlobRef? area,
  required BlobRef? heading,
  required Object Function(String) throwing,
}) {
  if (project != null && area != null) {
    throw throwing('a task is in a project or an area, never both');
  }
  if (heading != null && project == null) {
    throw throwing('a heading placement requires its project');
  }
}

void _checkCreatedAt({
  required DateTime? createdAt,
  required ExternalRef? external,
  required Object Function(String) throwing,
}) {
  if (createdAt != null && external == null) {
    throw throwing(
      'created_at is an import-only override and requires external',
    );
  }
}

/// `task.create` — the sealed event's id is the task's id.
final class TaskCreated extends TaskEvent {
  TaskCreated({
    required this.title,
    this.notes = '',
    this.when = TaskWhen.none,
    this.deadline,
    this.project,
    this.area,
    this.heading,
    List<TagId> tags = const [],
    List<ChecklistItem> checklist = const [],
    this.createdAt,
    this.external,
  }) : tags = List.unmodifiable(tags),
       checklist = List.unmodifiable(checklist) {
    if (title.isEmpty) {
      throw ArgumentError('title must not be empty');
    }
    _checkPlacement(
      project: project,
      area: area,
      heading: heading,
      throwing: ArgumentError.new,
    );
    _checkCreatedAt(
      createdAt: createdAt,
      external: external,
      throwing: ArgumentError.new,
    );
  }

  final String title;
  final String notes;
  final TaskWhen when;
  final CalendarDate? deadline;
  final ProjectId? project;
  final AreaId? area;
  final HeadingId? heading;
  final List<TagId> tags;
  final List<ChecklistItem> checklist;

  /// Import-only override of the creation instant; requires [external].
  final DateTime? createdAt;

  final ExternalRef? external;

  @override
  String get type => TaskEventTypes.taskCreate;

  @override
  BlobRef? get subject => null;

  @override
  Map<String, Object?> toPayload() => {
    'title': title,
    if (notes.isNotEmpty) 'notes': notes,
    if (when != TaskWhen.none) 'when': when.toJson(),
    if (deadline != null) 'deadline': deadline!.toJson(),
    if (project != null) 'project': project!.toString(),
    if (area != null) 'area': area!.toString(),
    if (heading != null) 'heading': heading!.toString(),
    if (tags.isNotEmpty) 'tags': [for (final t in tags) t.toString()],
    if (checklist.isNotEmpty)
      'checklist': [for (final item in checklist) item.toJson()],
    if (createdAt != null) 'created_at': formatTs(createdAt!),
    if (external != null) 'external': external!.toJson(),
  };

  factory TaskCreated._decode(Map<String, Object?> payload) {
    const where = TaskEventTypes.taskCreate;
    rejectUnknownKeys(payload, const {
      'title',
      'notes',
      'when',
      'deadline',
      'project',
      'area',
      'heading',
      'tags',
      'checklist',
      'created_at',
      'external',
    }, where: where);
    final project = optionalId(payload, 'project', where: where);
    final area = optionalId(payload, 'area', where: where);
    final heading = optionalId(payload, 'heading', where: where);
    _checkPlacement(
      project: project,
      area: area,
      heading: heading,
      throwing: FormatException.new,
    );
    final createdAt = optionalInstant(payload, 'created_at', where: where);
    final external = payload['external'] == null
        ? null
        : ExternalRef.fromJson(payload['external']);
    _checkCreatedAt(
      createdAt: createdAt,
      external: external,
      throwing: FormatException.new,
    );
    return TaskCreated(
      title: requireString(payload, 'title', where: where),
      notes:
          optionalString(payload, 'notes', where: where, emptyOk: true) ?? '',
      when: TaskWhen.fromJson(payload['when']),
      deadline: optionalDate(payload, 'deadline', where: where),
      project: project,
      area: area,
      heading: heading,
      tags: idList(payload, 'tags', where: where),
      checklist: [
        for (final item in jsonList(payload, 'checklist', where: where))
          ChecklistItem.fromJson(item),
      ],
      createdAt: createdAt,
      external: external,
    );
  }
}

/// `task.edit` — field-set semantics: a key present means "set", a JSON
/// null clears, an absent key leaves the field alone. Placement never moves
/// here; that is `task.move`.
final class TaskEdited extends TaskEvent {
  TaskEdited(
    this.task, {
    this.title,
    this.notes,
    this.when,
    this.deadline,
    this.tags,
  }) {
    if (title == null &&
        notes == null &&
        when == null &&
        deadline == null &&
        tags == null) {
      throw ArgumentError('an edit must set at least one field');
    }
    if (title != null && title!.value.isEmpty) {
      throw ArgumentError('title must not be empty');
    }
  }

  final TaskId task;
  final Patch<String>? title;
  final Patch<String>? notes;
  final Patch<TaskWhen>? when;
  final Patch<CalendarDate?>? deadline;
  final Patch<List<TagId>>? tags;

  @override
  String get type => TaskEventTypes.taskEdit;

  @override
  BlobRef? get subject => task;

  @override
  Map<String, Object?> toPayload() => {
    'task': task.toString(),
    if (title != null) 'title': title!.value,
    if (notes != null) 'notes': notes!.value,
    if (when != null) 'when': when!.value.toJson(),
    if (deadline != null) 'deadline': deadline!.value?.toJson(),
    if (tags != null) 'tags': [for (final t in tags!.value) t.toString()],
  };

  factory TaskEdited._decode(Map<String, Object?> payload) {
    const where = TaskEventTypes.taskEdit;
    rejectUnknownKeys(payload, const {
      'task',
      'title',
      'notes',
      'when',
      'deadline',
      'tags',
    }, where: where);
    if (payload.keys.where((k) => k != 'task').isEmpty) {
      throw const FormatException('an edit must set at least one field');
    }
    return TaskEdited(
      requireId(payload, 'task', where: where),
      title: payload.containsKey('title')
          ? Patch(requireString(payload, 'title', where: where))
          : null,
      notes: payload.containsKey('notes')
          ? Patch(
              optionalString(payload, 'notes', where: where, emptyOk: true) ??
                  (throw FormatException(
                    '$where.notes clears to "", not null',
                  )),
            )
          : null,
      when: payload.containsKey('when')
          ? Patch(TaskWhen.fromJson(payload['when']))
          : null,
      deadline: payload.containsKey('deadline')
          ? Patch(optionalDate(payload, 'deadline', where: where))
          : null,
      tags: payload.containsKey('tags')
          ? Patch(idList(payload, 'tags', where: where))
          : null,
    );
  }
}

/// `task.move` — a full placement replacement: every placement key is
/// written, so the line is unambiguous on its own.
final class TaskMoved extends TaskEvent {
  TaskMoved(this.task, {this.project, this.area, this.heading}) {
    _checkPlacement(
      project: project,
      area: area,
      heading: heading,
      throwing: ArgumentError.new,
    );
  }

  final TaskId task;
  final ProjectId? project;
  final AreaId? area;
  final HeadingId? heading;

  @override
  String get type => TaskEventTypes.taskMove;

  @override
  BlobRef? get subject => task;

  @override
  List<BlobRef> get refs => [task, ?project, ?area, ?heading];

  @override
  Map<String, Object?> toPayload() => {
    'task': task.toString(),
    'project': project?.toString(),
    'area': area?.toString(),
    'heading': heading?.toString(),
  };

  factory TaskMoved._decode(Map<String, Object?> payload) {
    const where = TaskEventTypes.taskMove;
    rejectUnknownKeys(payload, const {
      'task',
      'project',
      'area',
      'heading',
    }, where: where);
    for (final key in const ['project', 'area', 'heading']) {
      if (!payload.containsKey(key)) {
        throw FormatException(
          '$where writes every placement key; $key is '
          'missing',
        );
      }
    }
    final project = optionalId(payload, 'project', where: where);
    final area = optionalId(payload, 'area', where: where);
    final heading = optionalId(payload, 'heading', where: where);
    _checkPlacement(
      project: project,
      area: area,
      heading: heading,
      throwing: FormatException.new,
    );
    return TaskMoved(
      requireId(payload, 'task', where: where),
      project: project,
      area: area,
      heading: heading,
    );
  }
}

/// `task.complete` — [at] defaults to the event's own timestamp; an
/// explicit value carries imported history.
final class TaskCompleted extends TaskEvent {
  const TaskCompleted(this.task, {this.at});

  final TaskId task;
  final DateTime? at;

  @override
  String get type => TaskEventTypes.taskComplete;

  @override
  BlobRef? get subject => task;

  @override
  Map<String, Object?> toPayload() => {
    'task': task.toString(),
    if (at != null) 'at': formatTs(at!),
  };

  factory TaskCompleted._decode(Map<String, Object?> payload) {
    const where = TaskEventTypes.taskComplete;
    rejectUnknownKeys(payload, const {'task', 'at'}, where: where);
    return TaskCompleted(
      requireId(payload, 'task', where: where),
      at: optionalInstant(payload, 'at', where: where),
    );
  }
}

/// `task.cancel` — see [TaskCompleted] for [at].
final class TaskCancelled extends TaskEvent {
  const TaskCancelled(this.task, {this.at});

  final TaskId task;
  final DateTime? at;

  @override
  String get type => TaskEventTypes.taskCancel;

  @override
  BlobRef? get subject => task;

  @override
  Map<String, Object?> toPayload() => {
    'task': task.toString(),
    if (at != null) 'at': formatTs(at!),
  };

  factory TaskCancelled._decode(Map<String, Object?> payload) {
    const where = TaskEventTypes.taskCancel;
    rejectUnknownKeys(payload, const {'task', 'at'}, where: where);
    return TaskCancelled(
      requireId(payload, 'task', where: where),
      at: optionalInstant(payload, 'at', where: where),
    );
  }
}

TaskEvent Function(Map<String, Object?>) _subjectOnly(
  String where,
  String key,
  TaskEvent Function(BlobRef) build,
) => (payload) {
  rejectUnknownKeys(payload, {key}, where: where);
  return build(requireId(payload, key, where: where));
};

/// `task.reopen` — clears completion and cancellation.
final class TaskReopened extends TaskEvent {
  const TaskReopened(this.task);

  final TaskId task;

  @override
  String get type => TaskEventTypes.taskReopen;

  @override
  BlobRef? get subject => task;

  @override
  Map<String, Object?> toPayload() => {'task': task.toString()};
}

/// `task.delete` — soft: the log keeps the history, the projection stops
/// showing the task.
final class TaskDeleted extends TaskEvent {
  const TaskDeleted(this.task);

  final TaskId task;

  @override
  String get type => TaskEventTypes.taskDelete;

  @override
  BlobRef? get subject => task;

  @override
  Map<String, Object?> toPayload() => {'task': task.toString()};
}

/// `task.restore` — undoes `task.delete`.
final class TaskRestored extends TaskEvent {
  const TaskRestored(this.task);

  final TaskId task;

  @override
  String get type => TaskEventTypes.taskRestore;

  @override
  BlobRef? get subject => task;

  @override
  Map<String, Object?> toPayload() => {'task': task.toString()};
}

/// `task.checklist` — replaces the whole ordered checklist.
final class TaskChecklistSet extends TaskEvent {
  TaskChecklistSet(this.task, List<ChecklistItem> items)
    : items = List.unmodifiable(items);

  final TaskId task;
  final List<ChecklistItem> items;

  @override
  String get type => TaskEventTypes.taskChecklist;

  @override
  BlobRef? get subject => task;

  @override
  Map<String, Object?> toPayload() => {
    'task': task.toString(),
    'items': [for (final item in items) item.toJson()],
  };

  factory TaskChecklistSet._decode(Map<String, Object?> payload) {
    const where = TaskEventTypes.taskChecklist;
    rejectUnknownKeys(payload, const {'task', 'items'}, where: where);
    if (!payload.containsKey('items')) {
      throw const FormatException('task.checklist requires items');
    }
    return TaskChecklistSet(requireId(payload, 'task', where: where), [
      for (final item in jsonList(payload, 'items', where: where))
        ChecklistItem.fromJson(item),
    ]);
  }
}

/// `area.create`.
final class AreaCreated extends TaskEvent {
  AreaCreated({required this.title, this.createdAt, this.external}) {
    if (title.isEmpty) {
      throw ArgumentError('title must not be empty');
    }
    _checkCreatedAt(
      createdAt: createdAt,
      external: external,
      throwing: ArgumentError.new,
    );
  }

  final String title;
  final DateTime? createdAt;
  final ExternalRef? external;

  @override
  String get type => TaskEventTypes.areaCreate;

  @override
  BlobRef? get subject => null;

  @override
  Map<String, Object?> toPayload() => {
    'title': title,
    if (createdAt != null) 'created_at': formatTs(createdAt!),
    if (external != null) 'external': external!.toJson(),
  };

  factory AreaCreated._decode(Map<String, Object?> payload) {
    const where = TaskEventTypes.areaCreate;
    rejectUnknownKeys(payload, const {
      'title',
      'created_at',
      'external',
    }, where: where);
    final createdAt = optionalInstant(payload, 'created_at', where: where);
    final external = payload['external'] == null
        ? null
        : ExternalRef.fromJson(payload['external']);
    _checkCreatedAt(
      createdAt: createdAt,
      external: external,
      throwing: FormatException.new,
    );
    return AreaCreated(
      title: requireString(payload, 'title', where: where),
      createdAt: createdAt,
      external: external,
    );
  }
}

/// `area.edit`.
final class AreaEdited extends TaskEvent {
  AreaEdited(this.area, {this.title}) {
    if (title == null) {
      throw ArgumentError('an edit must set at least one field');
    }
    if (title!.value.isEmpty) {
      throw ArgumentError('title must not be empty');
    }
  }

  final AreaId area;
  final Patch<String>? title;

  @override
  String get type => TaskEventTypes.areaEdit;

  @override
  BlobRef? get subject => area;

  @override
  Map<String, Object?> toPayload() => {
    'area': area.toString(),
    if (title != null) 'title': title!.value,
  };

  factory AreaEdited._decode(Map<String, Object?> payload) {
    const where = TaskEventTypes.areaEdit;
    rejectUnknownKeys(payload, const {'area', 'title'}, where: where);
    if (!payload.containsKey('title')) {
      throw const FormatException('an edit must set at least one field');
    }
    return AreaEdited(
      requireId(payload, 'area', where: where),
      title: Patch(requireString(payload, 'title', where: where)),
    );
  }
}

/// `area.delete` — soft.
final class AreaDeleted extends TaskEvent {
  const AreaDeleted(this.area);

  final AreaId area;

  @override
  String get type => TaskEventTypes.areaDelete;

  @override
  BlobRef? get subject => area;

  @override
  Map<String, Object?> toPayload() => {'area': area.toString()};
}

/// `area.restore`.
final class AreaRestored extends TaskEvent {
  const AreaRestored(this.area);

  final AreaId area;

  @override
  String get type => TaskEventTypes.areaRestore;

  @override
  BlobRef? get subject => area;

  @override
  Map<String, Object?> toPayload() => {'area': area.toString()};
}

/// `project.create`.
final class ProjectCreated extends TaskEvent {
  ProjectCreated({
    required this.title,
    this.notes = '',
    this.area,
    this.when = TaskWhen.none,
    this.deadline,
    List<TagId> tags = const [],
    this.createdAt,
    this.external,
  }) : tags = List.unmodifiable(tags) {
    if (title.isEmpty) {
      throw ArgumentError('title must not be empty');
    }
    _checkCreatedAt(
      createdAt: createdAt,
      external: external,
      throwing: ArgumentError.new,
    );
  }

  final String title;
  final String notes;
  final AreaId? area;
  final TaskWhen when;
  final CalendarDate? deadline;
  final List<TagId> tags;
  final DateTime? createdAt;
  final ExternalRef? external;

  @override
  String get type => TaskEventTypes.projectCreate;

  @override
  BlobRef? get subject => null;

  @override
  Map<String, Object?> toPayload() => {
    'title': title,
    if (notes.isNotEmpty) 'notes': notes,
    if (area != null) 'area': area!.toString(),
    if (when != TaskWhen.none) 'when': when.toJson(),
    if (deadline != null) 'deadline': deadline!.toJson(),
    if (tags.isNotEmpty) 'tags': [for (final t in tags) t.toString()],
    if (createdAt != null) 'created_at': formatTs(createdAt!),
    if (external != null) 'external': external!.toJson(),
  };

  factory ProjectCreated._decode(Map<String, Object?> payload) {
    const where = TaskEventTypes.projectCreate;
    rejectUnknownKeys(payload, const {
      'title',
      'notes',
      'area',
      'when',
      'deadline',
      'tags',
      'created_at',
      'external',
    }, where: where);
    final createdAt = optionalInstant(payload, 'created_at', where: where);
    final external = payload['external'] == null
        ? null
        : ExternalRef.fromJson(payload['external']);
    _checkCreatedAt(
      createdAt: createdAt,
      external: external,
      throwing: FormatException.new,
    );
    return ProjectCreated(
      title: requireString(payload, 'title', where: where),
      notes:
          optionalString(payload, 'notes', where: where, emptyOk: true) ?? '',
      area: optionalId(payload, 'area', where: where),
      when: TaskWhen.fromJson(payload['when']),
      deadline: optionalDate(payload, 'deadline', where: where),
      tags: idList(payload, 'tags', where: where),
      createdAt: createdAt,
      external: external,
    );
  }
}

/// `project.edit` — field-set semantics, like `task.edit`.
final class ProjectEdited extends TaskEvent {
  ProjectEdited(
    this.project, {
    this.title,
    this.notes,
    this.area,
    this.when,
    this.deadline,
    this.tags,
  }) {
    if (title == null &&
        notes == null &&
        area == null &&
        when == null &&
        deadline == null &&
        tags == null) {
      throw ArgumentError('an edit must set at least one field');
    }
    if (title != null && title!.value.isEmpty) {
      throw ArgumentError('title must not be empty');
    }
  }

  final ProjectId project;
  final Patch<String>? title;
  final Patch<String>? notes;
  final Patch<AreaId?>? area;
  final Patch<TaskWhen>? when;
  final Patch<CalendarDate?>? deadline;
  final Patch<List<TagId>>? tags;

  @override
  String get type => TaskEventTypes.projectEdit;

  @override
  BlobRef? get subject => project;

  @override
  Map<String, Object?> toPayload() => {
    'project': project.toString(),
    if (title != null) 'title': title!.value,
    if (notes != null) 'notes': notes!.value,
    if (area != null) 'area': area!.value?.toString(),
    if (when != null) 'when': when!.value.toJson(),
    if (deadline != null) 'deadline': deadline!.value?.toJson(),
    if (tags != null) 'tags': [for (final t in tags!.value) t.toString()],
  };

  factory ProjectEdited._decode(Map<String, Object?> payload) {
    const where = TaskEventTypes.projectEdit;
    rejectUnknownKeys(payload, const {
      'project',
      'title',
      'notes',
      'area',
      'when',
      'deadline',
      'tags',
    }, where: where);
    if (payload.keys.where((k) => k != 'project').isEmpty) {
      throw const FormatException('an edit must set at least one field');
    }
    return ProjectEdited(
      requireId(payload, 'project', where: where),
      title: payload.containsKey('title')
          ? Patch(requireString(payload, 'title', where: where))
          : null,
      notes: payload.containsKey('notes')
          ? Patch(
              optionalString(payload, 'notes', where: where, emptyOk: true) ??
                  (throw FormatException(
                    '$where.notes clears to "", not null',
                  )),
            )
          : null,
      area: payload.containsKey('area')
          ? Patch(optionalId(payload, 'area', where: where))
          : null,
      when: payload.containsKey('when')
          ? Patch(TaskWhen.fromJson(payload['when']))
          : null,
      deadline: payload.containsKey('deadline')
          ? Patch(optionalDate(payload, 'deadline', where: where))
          : null,
      tags: payload.containsKey('tags')
          ? Patch(idList(payload, 'tags', where: where))
          : null,
    );
  }
}

/// `project.delete` — soft.
final class ProjectDeleted extends TaskEvent {
  const ProjectDeleted(this.project);

  final ProjectId project;

  @override
  String get type => TaskEventTypes.projectDelete;

  @override
  BlobRef? get subject => project;

  @override
  Map<String, Object?> toPayload() => {'project': project.toString()};
}

/// `project.restore`.
final class ProjectRestored extends TaskEvent {
  const ProjectRestored(this.project);

  final ProjectId project;

  @override
  String get type => TaskEventTypes.projectRestore;

  @override
  BlobRef? get subject => project;

  @override
  Map<String, Object?> toPayload() => {'project': project.toString()};
}

/// `heading.create` — inside one project, always.
final class HeadingCreated extends TaskEvent {
  HeadingCreated({
    required this.project,
    required this.title,
    this.createdAt,
    this.external,
  }) {
    if (title.isEmpty) {
      throw ArgumentError('title must not be empty');
    }
    _checkCreatedAt(
      createdAt: createdAt,
      external: external,
      throwing: ArgumentError.new,
    );
  }

  final ProjectId project;
  final String title;
  final DateTime? createdAt;
  final ExternalRef? external;

  @override
  String get type => TaskEventTypes.headingCreate;

  @override
  BlobRef? get subject => null;

  @override
  List<BlobRef> get refs => [project];

  @override
  Map<String, Object?> toPayload() => {
    'project': project.toString(),
    'title': title,
    if (createdAt != null) 'created_at': formatTs(createdAt!),
    if (external != null) 'external': external!.toJson(),
  };

  factory HeadingCreated._decode(Map<String, Object?> payload) {
    const where = TaskEventTypes.headingCreate;
    rejectUnknownKeys(payload, const {
      'project',
      'title',
      'created_at',
      'external',
    }, where: where);
    final createdAt = optionalInstant(payload, 'created_at', where: where);
    final external = payload['external'] == null
        ? null
        : ExternalRef.fromJson(payload['external']);
    _checkCreatedAt(
      createdAt: createdAt,
      external: external,
      throwing: FormatException.new,
    );
    return HeadingCreated(
      project: requireId(payload, 'project', where: where),
      title: requireString(payload, 'title', where: where),
      createdAt: createdAt,
      external: external,
    );
  }
}

/// `heading.edit`.
final class HeadingEdited extends TaskEvent {
  HeadingEdited(this.heading, {this.title}) {
    if (title == null) {
      throw ArgumentError('an edit must set at least one field');
    }
    if (title!.value.isEmpty) {
      throw ArgumentError('title must not be empty');
    }
  }

  final HeadingId heading;
  final Patch<String>? title;

  @override
  String get type => TaskEventTypes.headingEdit;

  @override
  BlobRef? get subject => heading;

  @override
  Map<String, Object?> toPayload() => {
    'heading': heading.toString(),
    if (title != null) 'title': title!.value,
  };

  factory HeadingEdited._decode(Map<String, Object?> payload) {
    const where = TaskEventTypes.headingEdit;
    rejectUnknownKeys(payload, const {'heading', 'title'}, where: where);
    if (!payload.containsKey('title')) {
      throw const FormatException('an edit must set at least one field');
    }
    return HeadingEdited(
      requireId(payload, 'heading', where: where),
      title: Patch(requireString(payload, 'title', where: where)),
    );
  }
}

/// `heading.delete` — soft.
final class HeadingDeleted extends TaskEvent {
  const HeadingDeleted(this.heading);

  final HeadingId heading;

  @override
  String get type => TaskEventTypes.headingDelete;

  @override
  BlobRef? get subject => heading;

  @override
  Map<String, Object?> toPayload() => {'heading': heading.toString()};
}

/// `heading.restore`.
final class HeadingRestored extends TaskEvent {
  const HeadingRestored(this.heading);

  final HeadingId heading;

  @override
  String get type => TaskEventTypes.headingRestore;

  @override
  BlobRef? get subject => heading;

  @override
  Map<String, Object?> toPayload() => {'heading': heading.toString()};
}

/// `tag.create`.
final class TagCreated extends TaskEvent {
  TagCreated({
    required this.title,
    this.parent,
    this.createdAt,
    this.external,
  }) {
    if (title.isEmpty) {
      throw ArgumentError('title must not be empty');
    }
    _checkCreatedAt(
      createdAt: createdAt,
      external: external,
      throwing: ArgumentError.new,
    );
  }

  final String title;
  final TagId? parent;
  final DateTime? createdAt;
  final ExternalRef? external;

  @override
  String get type => TaskEventTypes.tagCreate;

  @override
  BlobRef? get subject => null;

  @override
  Map<String, Object?> toPayload() => {
    'title': title,
    if (parent != null) 'parent': parent!.toString(),
    if (createdAt != null) 'created_at': formatTs(createdAt!),
    if (external != null) 'external': external!.toJson(),
  };

  factory TagCreated._decode(Map<String, Object?> payload) {
    const where = TaskEventTypes.tagCreate;
    rejectUnknownKeys(payload, const {
      'title',
      'parent',
      'created_at',
      'external',
    }, where: where);
    final createdAt = optionalInstant(payload, 'created_at', where: where);
    final external = payload['external'] == null
        ? null
        : ExternalRef.fromJson(payload['external']);
    _checkCreatedAt(
      createdAt: createdAt,
      external: external,
      throwing: FormatException.new,
    );
    return TagCreated(
      title: requireString(payload, 'title', where: where),
      parent: optionalId(payload, 'parent', where: where),
      createdAt: createdAt,
      external: external,
    );
  }
}

/// `tag.edit` — field-set semantics.
final class TagEdited extends TaskEvent {
  TagEdited(this.tag, {this.title, this.parent}) {
    if (title == null && parent == null) {
      throw ArgumentError('an edit must set at least one field');
    }
    if (title != null && title!.value.isEmpty) {
      throw ArgumentError('title must not be empty');
    }
  }

  final TagId tag;
  final Patch<String>? title;
  final Patch<TagId?>? parent;

  @override
  String get type => TaskEventTypes.tagEdit;

  @override
  BlobRef? get subject => tag;

  @override
  Map<String, Object?> toPayload() => {
    'tag': tag.toString(),
    if (title != null) 'title': title!.value,
    if (parent != null) 'parent': parent!.value?.toString(),
  };

  factory TagEdited._decode(Map<String, Object?> payload) {
    const where = TaskEventTypes.tagEdit;
    rejectUnknownKeys(payload, const {'tag', 'title', 'parent'}, where: where);
    if (payload.keys.where((k) => k != 'tag').isEmpty) {
      throw const FormatException('an edit must set at least one field');
    }
    return TagEdited(
      requireId(payload, 'tag', where: where),
      title: payload.containsKey('title')
          ? Patch(requireString(payload, 'title', where: where))
          : null,
      parent: payload.containsKey('parent')
          ? Patch(optionalId(payload, 'parent', where: where))
          : null,
    );
  }
}

/// `tag.delete` — soft.
final class TagDeleted extends TaskEvent {
  const TagDeleted(this.tag);

  final TagId tag;

  @override
  String get type => TaskEventTypes.tagDelete;

  @override
  BlobRef? get subject => tag;

  @override
  Map<String, Object?> toPayload() => {'tag': tag.toString()};
}

/// `tag.restore`.
final class TagRestored extends TaskEvent {
  const TagRestored(this.tag);

  final TagId tag;

  @override
  String get type => TaskEventTypes.tagRestore;

  @override
  BlobRef? get subject => tag;

  @override
  Map<String, Object?> toPayload() => {'tag': tag.toString()};
}

final _decoders = <String, TaskEvent Function(Map<String, Object?>)>{
  TaskEventTypes.taskCreate: TaskCreated._decode,
  TaskEventTypes.taskEdit: TaskEdited._decode,
  TaskEventTypes.taskMove: TaskMoved._decode,
  TaskEventTypes.taskComplete: TaskCompleted._decode,
  TaskEventTypes.taskCancel: TaskCancelled._decode,
  TaskEventTypes.taskReopen: _subjectOnly(
    TaskEventTypes.taskReopen,
    'task',
    TaskReopened.new,
  ),
  TaskEventTypes.taskDelete: _subjectOnly(
    TaskEventTypes.taskDelete,
    'task',
    TaskDeleted.new,
  ),
  TaskEventTypes.taskRestore: _subjectOnly(
    TaskEventTypes.taskRestore,
    'task',
    TaskRestored.new,
  ),
  TaskEventTypes.taskChecklist: TaskChecklistSet._decode,
  TaskEventTypes.areaCreate: AreaCreated._decode,
  TaskEventTypes.areaEdit: AreaEdited._decode,
  TaskEventTypes.areaDelete: _subjectOnly(
    TaskEventTypes.areaDelete,
    'area',
    AreaDeleted.new,
  ),
  TaskEventTypes.areaRestore: _subjectOnly(
    TaskEventTypes.areaRestore,
    'area',
    AreaRestored.new,
  ),
  TaskEventTypes.projectCreate: ProjectCreated._decode,
  TaskEventTypes.projectEdit: ProjectEdited._decode,
  TaskEventTypes.projectDelete: _subjectOnly(
    TaskEventTypes.projectDelete,
    'project',
    ProjectDeleted.new,
  ),
  TaskEventTypes.projectRestore: _subjectOnly(
    TaskEventTypes.projectRestore,
    'project',
    ProjectRestored.new,
  ),
  TaskEventTypes.headingCreate: HeadingCreated._decode,
  TaskEventTypes.headingEdit: HeadingEdited._decode,
  TaskEventTypes.headingDelete: _subjectOnly(
    TaskEventTypes.headingDelete,
    'heading',
    HeadingDeleted.new,
  ),
  TaskEventTypes.headingRestore: _subjectOnly(
    TaskEventTypes.headingRestore,
    'heading',
    HeadingRestored.new,
  ),
  TaskEventTypes.tagCreate: TagCreated._decode,
  TaskEventTypes.tagEdit: TagEdited._decode,
  TaskEventTypes.tagDelete: _subjectOnly(
    TaskEventTypes.tagDelete,
    'tag',
    TagDeleted.new,
  ),
  TaskEventTypes.tagRestore: _subjectOnly(
    TaskEventTypes.tagRestore,
    'tag',
    TagRestored.new,
  ),
};

/// Decodes [event] into its typed task-domain value, or returns null when
/// the type is not in the task family — core log types (`chat.message` …)
/// and types a newer sai may have added are skipped, never errors.
///
/// Throws [FormatException] when the type *is* in the family but the
/// payload violates its schema: only sai writes these lines, so that means
/// a bug or a hand-edited log.
TaskEvent? decodeTaskEvent(Event event) {
  final decoder = _decoders[event.type];
  if (decoder == null) return null;
  return decoder(event.payload);
}
