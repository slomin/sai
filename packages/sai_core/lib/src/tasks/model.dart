import '../archive/blobref.dart';
import '../archive/event.dart' show formatTs, parseTs;
import 'date.dart';

/// Entity ids are the blobref of the event that created the entity — see
/// `docs/tasks/task-model-v0.md`. The typedefs are readability aliases, not
/// new types: kind is checked at runtime by the projection's reducer.
typedef TaskId = BlobRef;
typedef ProjectId = BlobRef;
typedef HeadingId = BlobRef;
typedef AreaId = BlobRef;
typedef TagId = BlobRef;

/// An explicit "set this field" marker, distinguishing three states a bare
/// nullable parameter cannot: absent (leave alone), `Patch(null)` (clear),
/// and `Patch(v)` (set). Used by `copyWith` and by edit-event payloads.
final class Patch<T> {
  const Patch(this.value);

  final T value;
}

/// Where a task sits on the time axis: nowhere, on a concrete day, or in
/// Someday. JSON form: `null` | `"someday"` | `"2026-08-24"`.
sealed class TaskWhen {
  const TaskWhen._();

  static const TaskWhen none = TaskWhenNone._();
  static const TaskWhen someday = TaskWhenSomeday._();

  const factory TaskWhen.date(CalendarDate date) = TaskWhenDate;

  Object? toJson();

  static TaskWhen fromJson(Object? json) => switch (json) {
    null => none,
    'someday' => someday,
    final String text => TaskWhenDate(CalendarDate.parse(text)),
    _ => throw FormatException('when must be null, "someday" or a date'),
  };
}

final class TaskWhenNone extends TaskWhen {
  const TaskWhenNone._() : super._();

  @override
  Object? toJson() => null;
}

final class TaskWhenSomeday extends TaskWhen {
  const TaskWhenSomeday._() : super._();

  @override
  Object? toJson() => 'someday';
}

final class TaskWhenDate extends TaskWhen {
  const TaskWhenDate(this.date) : super._();

  final CalendarDate date;

  @override
  Object? toJson() => date.toJson();

  @override
  bool operator ==(Object other) => other is TaskWhenDate && other.date == date;

  @override
  int get hashCode => Object.hash(TaskWhenDate, date);
}

/// Task lifecycle, derived from the timestamps — never stored, so it cannot
/// desynchronise from them.
enum TaskStatus { open, completed, cancelled }

/// One entry of a task's checklist. Items have no identity in v0.1: the
/// `task.checklist` event replaces the whole ordered list.
final class ChecklistItem {
  const ChecklistItem({required this.title, this.completedAt});

  final String title;
  final DateTime? completedAt;

  Map<String, Object?> toJson() => {
    'title': title,
    'completed_at': completedAt == null ? null : formatTs(completedAt!),
  };

  factory ChecklistItem.fromJson(Object? json) {
    final map = _requireObject(json, 'checklist item');
    _rejectUnknownKeys(map, const {
      'title',
      'completed_at',
    }, where: 'checklist item');
    return ChecklistItem(
      title: _requireString(map, 'title', where: 'checklist item'),
      completedAt: _optionalInstant(
        map,
        'completed_at',
        where: 'checklist item',
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChecklistItem &&
      other.title == title &&
      other.completedAt == completedAt;

  @override
  int get hashCode => Object.hash(title, completedAt);
}

/// Where an imported entity came from, and the key that keeps re-imports
/// idempotent. For a materialised occurrence of a repeating task,
/// `instance` carries the occurrence date (see the model doc's
/// repeating-tasks deferral).
final class ExternalRef {
  const ExternalRef({
    required this.system,
    required this.id,
    this.version,
    this.instance,
  });

  /// The source system, e.g. `things3`.
  final String system;

  /// The entity's id in the source system.
  final String id;

  /// The source system's version, where known.
  final String? version;

  /// The occurrence date a repeating source item was materialised for.
  final String? instance;

  /// The projection's dedupe key.
  String get key => '$system:$id';

  Map<String, Object?> toJson() => {
    'system': system,
    'id': id,
    if (version != null) 'version': version,
    if (instance != null) 'instance': instance,
  };

  factory ExternalRef.fromJson(Object? json) {
    final map = _requireObject(json, 'external');
    _rejectUnknownKeys(map, const {
      'system',
      'id',
      'version',
      'instance',
    }, where: 'external');
    return ExternalRef(
      system: _requireString(map, 'system', where: 'external'),
      id: _requireString(map, 'id', where: 'external'),
      version: _optionalString(map, 'version', where: 'external'),
      instance: _optionalString(map, 'instance', where: 'external'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ExternalRef &&
      other.system == system &&
      other.id == id &&
      other.version == version &&
      other.instance == instance;

  @override
  int get hashCode => Object.hash(system, id, version, instance);
}

/// A task — the Things 3 subset v0.1 honours. Immutable; every mutation is
/// an archive event applied by the projection's reducer.
final class Task {
  Task({
    required this.id,
    required this.title,
    this.notes = '',
    this.when = TaskWhen.none,
    this.deadline,
    this.project,
    this.area,
    this.heading,
    List<TagId> tags = const [],
    List<ChecklistItem> checklist = const [],
    required this.createdAt,
    required this.modifiedAt,
    this.completedAt,
    this.cancelledAt,
    this.deletedAt,
    this.external,
  }) : tags = List.unmodifiable(tags),
       checklist = List.unmodifiable(checklist);

  final TaskId id;
  final String title;

  /// Markdown.
  final String notes;

  final TaskWhen when;
  final CalendarDate? deadline;
  final ProjectId? project;
  final AreaId? area;

  /// Non-null implies [project] is the heading's project.
  final HeadingId? heading;

  final List<TagId> tags;
  final List<ChecklistItem> checklist;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final DateTime? completedAt;
  final DateTime? cancelledAt;
  final DateTime? deletedAt;
  final ExternalRef? external;

  TaskStatus get status => cancelledAt != null
      ? TaskStatus.cancelled
      : completedAt != null
      ? TaskStatus.completed
      : TaskStatus.open;

  Task copyWith({
    Patch<String>? title,
    Patch<String>? notes,
    Patch<TaskWhen>? when,
    Patch<CalendarDate?>? deadline,
    Patch<ProjectId?>? project,
    Patch<AreaId?>? area,
    Patch<HeadingId?>? heading,
    Patch<List<TagId>>? tags,
    Patch<List<ChecklistItem>>? checklist,
    Patch<DateTime>? modifiedAt,
    Patch<DateTime?>? completedAt,
    Patch<DateTime?>? cancelledAt,
    Patch<DateTime?>? deletedAt,
    Patch<ExternalRef?>? external,
  }) => Task(
    id: id,
    title: title == null ? this.title : title.value,
    notes: notes == null ? this.notes : notes.value,
    when: when == null ? this.when : when.value,
    deadline: deadline == null ? this.deadline : deadline.value,
    project: project == null ? this.project : project.value,
    area: area == null ? this.area : area.value,
    heading: heading == null ? this.heading : heading.value,
    tags: tags == null ? this.tags : tags.value,
    checklist: checklist == null ? this.checklist : checklist.value,
    createdAt: createdAt,
    modifiedAt: modifiedAt == null ? this.modifiedAt : modifiedAt.value,
    completedAt: completedAt == null ? this.completedAt : completedAt.value,
    cancelledAt: cancelledAt == null ? this.cancelledAt : cancelledAt.value,
    deletedAt: deletedAt == null ? this.deletedAt : deletedAt.value,
    external: external == null ? this.external : external.value,
  );

  Map<String, Object?> toJson() => {
    'id': id.toString(),
    'title': title,
    'notes': notes,
    'when': when.toJson(),
    'deadline': deadline?.toJson(),
    'project': project?.toString(),
    'area': area?.toString(),
    'heading': heading?.toString(),
    'tags': [for (final tag in tags) tag.toString()],
    'checklist': [for (final item in checklist) item.toJson()],
    'created_at': formatTs(createdAt),
    'modified_at': formatTs(modifiedAt),
    'completed_at': completedAt == null ? null : formatTs(completedAt!),
    'cancelled_at': cancelledAt == null ? null : formatTs(cancelledAt!),
    'deleted_at': deletedAt == null ? null : formatTs(deletedAt!),
    'external': external?.toJson(),
  };

  factory Task.fromJson(Object? json) {
    final map = _requireObject(json, 'task');
    _rejectUnknownKeys(map, const {
      'id',
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
      'modified_at',
      'completed_at',
      'cancelled_at',
      'deleted_at',
      'external',
    }, where: 'task');
    return Task(
      id: _requireId(map, 'id', where: 'task'),
      title: _requireString(map, 'title', where: 'task'),
      notes: _optionalString(map, 'notes', where: 'task', emptyOk: true) ?? '',
      when: TaskWhen.fromJson(map['when']),
      deadline: _optionalDate(map, 'deadline', where: 'task'),
      project: _optionalId(map, 'project', where: 'task'),
      area: _optionalId(map, 'area', where: 'task'),
      heading: _optionalId(map, 'heading', where: 'task'),
      tags: _idList(map, 'tags', where: 'task'),
      checklist: [
        for (final item in _list(map, 'checklist', where: 'task'))
          ChecklistItem.fromJson(item),
      ],
      createdAt: _requireInstant(map, 'created_at', where: 'task'),
      modifiedAt: _requireInstant(map, 'modified_at', where: 'task'),
      completedAt: _optionalInstant(map, 'completed_at', where: 'task'),
      cancelledAt: _optionalInstant(map, 'cancelled_at', where: 'task'),
      deletedAt: _optionalInstant(map, 'deleted_at', where: 'task'),
      external: map['external'] == null
          ? null
          : ExternalRef.fromJson(map['external']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Task &&
      other.id == id &&
      other.title == title &&
      other.notes == notes &&
      other.when == when &&
      other.deadline == deadline &&
      other.project == project &&
      other.area == area &&
      other.heading == heading &&
      _listEquals(other.tags, tags) &&
      _listEquals(other.checklist, checklist) &&
      other.createdAt == createdAt &&
      other.modifiedAt == modifiedAt &&
      other.completedAt == completedAt &&
      other.cancelledAt == cancelledAt &&
      other.deletedAt == deletedAt &&
      other.external == external;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    notes,
    when,
    deadline,
    project,
    area,
    heading,
    Object.hashAll(tags),
    Object.hashAll(checklist),
    createdAt,
    modifiedAt,
    completedAt,
    cancelledAt,
    deletedAt,
    external,
  );
}

/// A project: a container of tasks (optionally under headings), itself
/// filed in an area or standalone.
final class Project {
  Project({
    required this.id,
    required this.title,
    this.notes = '',
    this.area,
    this.when = TaskWhen.none,
    this.deadline,
    List<TagId> tags = const [],
    required this.createdAt,
    required this.modifiedAt,
    this.deletedAt,
    this.external,
  }) : tags = List.unmodifiable(tags);

  final ProjectId id;
  final String title;
  final String notes;
  final AreaId? area;
  final TaskWhen when;
  final CalendarDate? deadline;
  final List<TagId> tags;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final DateTime? deletedAt;
  final ExternalRef? external;

  Project copyWith({
    Patch<String>? title,
    Patch<String>? notes,
    Patch<AreaId?>? area,
    Patch<TaskWhen>? when,
    Patch<CalendarDate?>? deadline,
    Patch<List<TagId>>? tags,
    Patch<DateTime>? modifiedAt,
    Patch<DateTime?>? deletedAt,
  }) => Project(
    id: id,
    title: title == null ? this.title : title.value,
    notes: notes == null ? this.notes : notes.value,
    area: area == null ? this.area : area.value,
    when: when == null ? this.when : when.value,
    deadline: deadline == null ? this.deadline : deadline.value,
    tags: tags == null ? this.tags : tags.value,
    createdAt: createdAt,
    modifiedAt: modifiedAt == null ? this.modifiedAt : modifiedAt.value,
    deletedAt: deletedAt == null ? this.deletedAt : deletedAt.value,
    external: external,
  );

  Map<String, Object?> toJson() => {
    'id': id.toString(),
    'title': title,
    'notes': notes,
    'area': area?.toString(),
    'when': when.toJson(),
    'deadline': deadline?.toJson(),
    'tags': [for (final tag in tags) tag.toString()],
    'created_at': formatTs(createdAt),
    'modified_at': formatTs(modifiedAt),
    'deleted_at': deletedAt == null ? null : formatTs(deletedAt!),
    'external': external?.toJson(),
  };

  factory Project.fromJson(Object? json) {
    final map = _requireObject(json, 'project');
    _rejectUnknownKeys(map, const {
      'id',
      'title',
      'notes',
      'area',
      'when',
      'deadline',
      'tags',
      'created_at',
      'modified_at',
      'deleted_at',
      'external',
    }, where: 'project');
    return Project(
      id: _requireId(map, 'id', where: 'project'),
      title: _requireString(map, 'title', where: 'project'),
      notes:
          _optionalString(map, 'notes', where: 'project', emptyOk: true) ?? '',
      area: _optionalId(map, 'area', where: 'project'),
      when: TaskWhen.fromJson(map['when']),
      deadline: _optionalDate(map, 'deadline', where: 'project'),
      tags: _idList(map, 'tags', where: 'project'),
      createdAt: _requireInstant(map, 'created_at', where: 'project'),
      modifiedAt: _requireInstant(map, 'modified_at', where: 'project'),
      deletedAt: _optionalInstant(map, 'deleted_at', where: 'project'),
      external: map['external'] == null
          ? null
          : ExternalRef.fromJson(map['external']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Project &&
      other.id == id &&
      other.title == title &&
      other.notes == notes &&
      other.area == area &&
      other.when == when &&
      other.deadline == deadline &&
      _listEquals(other.tags, tags) &&
      other.createdAt == createdAt &&
      other.modifiedAt == modifiedAt &&
      other.deletedAt == deletedAt &&
      other.external == external;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    notes,
    area,
    when,
    deadline,
    Object.hashAll(tags),
    createdAt,
    modifiedAt,
    deletedAt,
    external,
  );
}

/// A heading: a titled section inside one project.
final class Heading {
  const Heading({
    required this.id,
    required this.project,
    required this.title,
    required this.createdAt,
    required this.modifiedAt,
    this.deletedAt,
  });

  final HeadingId id;
  final ProjectId project;
  final String title;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final DateTime? deletedAt;

  Heading copyWith({
    Patch<String>? title,
    Patch<DateTime>? modifiedAt,
    Patch<DateTime?>? deletedAt,
  }) => Heading(
    id: id,
    project: project,
    title: title == null ? this.title : title.value,
    createdAt: createdAt,
    modifiedAt: modifiedAt == null ? this.modifiedAt : modifiedAt.value,
    deletedAt: deletedAt == null ? this.deletedAt : deletedAt.value,
  );

  Map<String, Object?> toJson() => {
    'id': id.toString(),
    'project': project.toString(),
    'title': title,
    'created_at': formatTs(createdAt),
    'modified_at': formatTs(modifiedAt),
    'deleted_at': deletedAt == null ? null : formatTs(deletedAt!),
  };

  factory Heading.fromJson(Object? json) {
    final map = _requireObject(json, 'heading');
    _rejectUnknownKeys(map, const {
      'id',
      'project',
      'title',
      'created_at',
      'modified_at',
      'deleted_at',
    }, where: 'heading');
    return Heading(
      id: _requireId(map, 'id', where: 'heading'),
      project: _requireId(map, 'project', where: 'heading'),
      title: _requireString(map, 'title', where: 'heading'),
      createdAt: _requireInstant(map, 'created_at', where: 'heading'),
      modifiedAt: _requireInstant(map, 'modified_at', where: 'heading'),
      deletedAt: _optionalInstant(map, 'deleted_at', where: 'heading'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Heading &&
      other.id == id &&
      other.project == project &&
      other.title == title &&
      other.createdAt == createdAt &&
      other.modifiedAt == modifiedAt &&
      other.deletedAt == deletedAt;

  @override
  int get hashCode =>
      Object.hash(id, project, title, createdAt, modifiedAt, deletedAt);
}

/// An area: a top-level sphere of life holding projects and tasks.
final class Area {
  const Area({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.modifiedAt,
    this.deletedAt,
    this.external,
  });

  final AreaId id;
  final String title;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final DateTime? deletedAt;
  final ExternalRef? external;

  Area copyWith({
    Patch<String>? title,
    Patch<DateTime>? modifiedAt,
    Patch<DateTime?>? deletedAt,
  }) => Area(
    id: id,
    title: title == null ? this.title : title.value,
    createdAt: createdAt,
    modifiedAt: modifiedAt == null ? this.modifiedAt : modifiedAt.value,
    deletedAt: deletedAt == null ? this.deletedAt : deletedAt.value,
    external: external,
  );

  Map<String, Object?> toJson() => {
    'id': id.toString(),
    'title': title,
    'created_at': formatTs(createdAt),
    'modified_at': formatTs(modifiedAt),
    'deleted_at': deletedAt == null ? null : formatTs(deletedAt!),
    'external': external?.toJson(),
  };

  factory Area.fromJson(Object? json) {
    final map = _requireObject(json, 'area');
    _rejectUnknownKeys(map, const {
      'id',
      'title',
      'created_at',
      'modified_at',
      'deleted_at',
      'external',
    }, where: 'area');
    return Area(
      id: _requireId(map, 'id', where: 'area'),
      title: _requireString(map, 'title', where: 'area'),
      createdAt: _requireInstant(map, 'created_at', where: 'area'),
      modifiedAt: _requireInstant(map, 'modified_at', where: 'area'),
      deletedAt: _optionalInstant(map, 'deleted_at', where: 'area'),
      external: map['external'] == null
          ? null
          : ExternalRef.fromJson(map['external']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Area &&
      other.id == id &&
      other.title == title &&
      other.createdAt == createdAt &&
      other.modifiedAt == modifiedAt &&
      other.deletedAt == deletedAt &&
      other.external == external;

  @override
  int get hashCode =>
      Object.hash(id, title, createdAt, modifiedAt, deletedAt, external);
}

/// A tag, optionally nested under a parent tag.
final class Tag {
  const Tag({
    required this.id,
    required this.title,
    this.parent,
    required this.createdAt,
    required this.modifiedAt,
    this.deletedAt,
  });

  final TagId id;
  final String title;
  final TagId? parent;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final DateTime? deletedAt;

  Tag copyWith({
    Patch<String>? title,
    Patch<TagId?>? parent,
    Patch<DateTime>? modifiedAt,
    Patch<DateTime?>? deletedAt,
  }) => Tag(
    id: id,
    title: title == null ? this.title : title.value,
    parent: parent == null ? this.parent : parent.value,
    createdAt: createdAt,
    modifiedAt: modifiedAt == null ? this.modifiedAt : modifiedAt.value,
    deletedAt: deletedAt == null ? this.deletedAt : deletedAt.value,
  );

  Map<String, Object?> toJson() => {
    'id': id.toString(),
    'title': title,
    'parent': parent?.toString(),
    'created_at': formatTs(createdAt),
    'modified_at': formatTs(modifiedAt),
    'deleted_at': deletedAt == null ? null : formatTs(deletedAt!),
  };

  factory Tag.fromJson(Object? json) {
    final map = _requireObject(json, 'tag');
    _rejectUnknownKeys(map, const {
      'id',
      'title',
      'parent',
      'created_at',
      'modified_at',
      'deleted_at',
    }, where: 'tag');
    return Tag(
      id: _requireId(map, 'id', where: 'tag'),
      title: _requireString(map, 'title', where: 'tag'),
      parent: _optionalId(map, 'parent', where: 'tag'),
      createdAt: _requireInstant(map, 'created_at', where: 'tag'),
      modifiedAt: _requireInstant(map, 'modified_at', where: 'tag'),
      deletedAt: _optionalInstant(map, 'deleted_at', where: 'tag'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Tag &&
      other.id == id &&
      other.title == title &&
      other.parent == parent &&
      other.createdAt == createdAt &&
      other.modifiedAt == modifiedAt &&
      other.deletedAt == deletedAt;

  @override
  int get hashCode =>
      Object.hash(id, title, parent, createdAt, modifiedAt, deletedAt);
}

// --- strict decode helpers, shared by the model and the event payloads ---

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Map<String, Object?> _requireObject(Object? value, String where) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$where must be a JSON object');
  }
  return value;
}

void _rejectUnknownKeys(
  Map<String, Object?> map,
  Set<String> allowed, {
  required String where,
}) {
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('unknown key in $where: "$key"');
    }
  }
}

String _requireString(
  Map<String, Object?> map,
  String key, {
  required String where,
}) {
  final value = map[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$where.$key must be a non-empty string');
  }
  return value;
}

String? _optionalString(
  Map<String, Object?> map,
  String key, {
  required String where,
  bool emptyOk = false,
}) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String || (!emptyOk && value.isEmpty)) {
    throw FormatException(
      '$where.$key must be a ${emptyOk ? '' : 'non-empty '}string',
    );
  }
  return value;
}

BlobRef _requireId(
  Map<String, Object?> map,
  String key, {
  required String where,
}) {
  final id = _optionalId(map, key, where: where);
  if (id == null) {
    throw FormatException('$where.$key must be a blobref');
  }
  return id;
}

BlobRef? _optionalId(
  Map<String, Object?> map,
  String key, {
  required String where,
}) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('$where.$key must be a blobref string');
  }
  try {
    return BlobRef.parse(value);
  } on FormatException {
    throw FormatException('$where.$key is not a blobref: "$value"');
  }
}

DateTime _requireInstant(
  Map<String, Object?> map,
  String key, {
  required String where,
}) {
  final instant = _optionalInstant(map, key, where: where);
  if (instant == null) {
    throw FormatException('$where.$key must be a timestamp');
  }
  return instant;
}

DateTime? _optionalInstant(
  Map<String, Object?> map,
  String key, {
  required String where,
}) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('$where.$key must be a timestamp string');
  }
  try {
    return parseTs(value);
  } on FormatException catch (e) {
    throw FormatException('$where.$key: ${e.message}');
  }
}

CalendarDate? _optionalDate(
  Map<String, Object?> map,
  String key, {
  required String where,
}) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('$where.$key must be a date string');
  }
  try {
    return CalendarDate.parse(value);
  } on FormatException catch (e) {
    throw FormatException('$where.$key: ${e.message}');
  }
}

List<Object?> _list(
  Map<String, Object?> map,
  String key, {
  required String where,
}) {
  final value = map[key];
  if (value == null) return const [];
  if (value is! List) {
    throw FormatException('$where.$key must be a list');
  }
  return value;
}

List<BlobRef> _idList(
  Map<String, Object?> map,
  String key, {
  required String where,
}) => [
  for (final entry in _list(map, key, where: where))
    () {
      if (entry is! String) {
        throw FormatException('$where.$key entries must be blobref strings');
      }
      try {
        return BlobRef.parse(entry);
      } on FormatException {
        throw FormatException('$where.$key entry is not a blobref: "$entry"');
      }
    }(),
];
