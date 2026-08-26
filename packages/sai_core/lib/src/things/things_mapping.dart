/// The pure half of the Things import: a [ThingsSnapshot] and the current
/// [TaskProjection] in, an [ImportPlan] of operations and an
/// [ImportReport] out. No I/O, no clock of its own, no sai ids minted —
/// operations name Things uuids and the applier resolves them, so a
/// dry-run prints exactly what a run would do.
///
/// Re-runs are idempotent through the projection's external index: an
/// entity whose `things3:<uuid>` is already known gets only the operations
/// that change what differs, and nothing at all when nothing does.
library;

import '../archive/blobref.dart';
import '../tasks/date.dart';
import '../tasks/model.dart';
import '../tasks/projection.dart';
import 'things_date.dart';
import 'things_db.dart';

/// What the applier does to one entity. `Create*` operations name
/// parents by Things uuid; `Edit*`/`Move*` operations carry the sai id
/// of an entity the projection already holds.
sealed class ImportOp {
  const ImportOp();

  /// The Things uuid this operation is about.
  String get uuid;

  /// One line for the dry-run listing. Carries the title — it is printed
  /// on the person's own terminal and nowhere else.
  String describe();
}

final class CreateArea extends ImportOp {
  const CreateArea({
    required this.uuid,
    required this.title,
    required this.createdAt,
  });

  @override
  final String uuid;
  final String title;
  final DateTime? createdAt;

  @override
  String describe() => '+ area "$title" ($uuid)';
}

final class EditArea extends ImportOp {
  const EditArea({required this.uuid, required this.id, required this.title});

  @override
  final String uuid;
  final AreaId id;
  final String title;

  @override
  String describe() => '~ area title "$title" ($uuid)';
}

final class CreateTag extends ImportOp {
  const CreateTag({
    required this.uuid,
    required this.title,
    required this.parent,
    required this.createdAt,
  });

  @override
  final String uuid;
  final String title;

  /// Parent tag uuid.
  final String? parent;
  final DateTime? createdAt;

  @override
  String describe() => '+ tag "$title" ($uuid)';
}

final class EditTag extends ImportOp {
  const EditTag({
    required this.uuid,
    required this.id,
    this.title,
    this.parent,
  });

  @override
  final String uuid;
  final TagId id;
  final Patch<String>? title;

  /// Parent tag uuid, or a patch to null.
  final Patch<String?>? parent;

  @override
  String describe() =>
      '~ tag ${[if (title != null) 'title', if (parent != null) 'parent'].join(',')} ($uuid)';
}

final class CreateProject extends ImportOp {
  const CreateProject({
    required this.uuid,
    required this.title,
    required this.notes,
    required this.area,
    required this.when,
    required this.deadline,
    required this.tags,
    required this.createdAt,
  });

  @override
  final String uuid;
  final String title;
  final String notes;

  /// Area uuid.
  final String? area;
  final TaskWhen when;
  final CalendarDate? deadline;

  /// Tag uuids.
  final List<String> tags;
  final DateTime? createdAt;

  @override
  String describe() => '+ project "$title" ($uuid)';
}

final class EditProject extends ImportOp {
  const EditProject({
    required this.uuid,
    required this.id,
    this.title,
    this.notes,
    this.area,
    this.when,
    this.deadline,
    this.tags,
  });

  @override
  final String uuid;
  final ProjectId id;
  final Patch<String>? title;
  final Patch<String>? notes;

  /// Area uuid, or a patch to null.
  final Patch<String?>? area;
  final Patch<TaskWhen>? when;
  final Patch<CalendarDate?>? deadline;

  /// Tag uuids.
  final Patch<List<String>>? tags;

  List<String> get fields => [
    if (title != null) 'title',
    if (notes != null) 'notes',
    if (area != null) 'area',
    if (when != null) 'when',
    if (deadline != null) 'deadline',
    if (tags != null) 'tags',
  ];

  @override
  String describe() => '~ project ${fields.join(',')} ($uuid)';
}

final class CreateHeading extends ImportOp {
  const CreateHeading({
    required this.uuid,
    required this.project,
    required this.title,
    required this.createdAt,
  });

  @override
  final String uuid;

  /// Project uuid.
  final String project;
  final String title;
  final DateTime? createdAt;

  @override
  String describe() => '+ heading "$title" ($uuid)';
}

final class EditHeading extends ImportOp {
  const EditHeading({
    required this.uuid,
    required this.id,
    required this.title,
  });

  @override
  final String uuid;
  final HeadingId id;
  final String title;

  @override
  String describe() => '~ heading title "$title" ($uuid)';
}

/// A task's placement by Things uuids; at most one of [area]/[project],
/// and [heading] only with [project].
final class ImportPlacement {
  const ImportPlacement({this.area, this.project, this.heading});

  final String? area;
  final String? project;
  final String? heading;
}

/// Open, completed or cancelled — with the instant when Things knows it
/// and the archive can take it (the event's own time otherwise).
enum ImportStatusKind { open, completed, cancelled }

final class ImportStatus {
  const ImportStatus.open() : kind = ImportStatusKind.open, at = null;
  const ImportStatus.completed(this.at) : kind = ImportStatusKind.completed;
  const ImportStatus.cancelled(this.at) : kind = ImportStatusKind.cancelled;

  final ImportStatusKind kind;
  final DateTime? at;

  bool get isOpen => kind == ImportStatusKind.open;

  /// Whether [task] already carries this status; an unknown [at] matches
  /// any instant of the right kind.
  bool matches(Task task) {
    final existingKind = switch (task.status) {
      TaskStatus.open => ImportStatusKind.open,
      TaskStatus.completed => ImportStatusKind.completed,
      TaskStatus.cancelled => ImportStatusKind.cancelled,
    };
    if (existingKind != kind) return false;
    if (at == null) return true;
    return switch (kind) {
      ImportStatusKind.open => true,
      ImportStatusKind.completed => task.completedAt == at,
      ImportStatusKind.cancelled => task.cancelledAt == at,
    };
  }
}

final class CreateTask extends ImportOp {
  const CreateTask({
    required this.uuid,
    required this.title,
    required this.notes,
    required this.when,
    required this.deadline,
    required this.placement,
    required this.tags,
    required this.checklist,
    required this.status,
    required this.createdAt,
    required this.instance,
  });

  @override
  final String uuid;
  final String title;
  final String notes;
  final TaskWhen when;
  final CalendarDate? deadline;
  final ImportPlacement placement;

  /// Tag uuids.
  final List<String> tags;
  final List<ChecklistItem> checklist;
  final ImportStatus status;
  final DateTime? createdAt;

  /// The repeating template's uuid for a materialised instance.
  final String? instance;

  @override
  String describe() => '+ task "$title" ($uuid)';
}

final class EditTask extends ImportOp {
  const EditTask({
    required this.uuid,
    required this.id,
    this.title,
    this.notes,
    this.when,
    this.deadline,
    this.tags,
  });

  @override
  final String uuid;
  final TaskId id;
  final Patch<String>? title;
  final Patch<String>? notes;
  final Patch<TaskWhen>? when;
  final Patch<CalendarDate?>? deadline;

  /// Tag uuids.
  final Patch<List<String>>? tags;

  List<String> get fields => [
    if (title != null) 'title',
    if (notes != null) 'notes',
    if (when != null) 'when',
    if (deadline != null) 'deadline',
    if (tags != null) 'tags',
  ];

  @override
  String describe() => '~ task ${fields.join(',')} ($uuid)';
}

final class MoveTask extends ImportOp {
  const MoveTask({
    required this.uuid,
    required this.id,
    required this.placement,
  });

  @override
  final String uuid;
  final TaskId id;
  final ImportPlacement placement;

  @override
  String describe() => '~ task placement ($uuid)';
}

final class SetTaskStatus extends ImportOp {
  const SetTaskStatus({
    required this.uuid,
    required this.id,
    required this.status,
  });

  @override
  final String uuid;
  final TaskId id;
  final ImportStatus status;

  @override
  String describe() {
    final what = switch (status.kind) {
      ImportStatusKind.open => 'reopen',
      ImportStatusKind.completed => 'complete',
      ImportStatusKind.cancelled => 'cancel',
    };
    return '~ task $what ($uuid)';
  }
}

final class SetTaskChecklist extends ImportOp {
  const SetTaskChecklist({
    required this.uuid,
    required this.id,
    required this.items,
  });

  @override
  final String uuid;
  final TaskId id;
  final List<ChecklistItem> items;

  @override
  String describe() => '~ task checklist ($uuid)';
}

/// The operations of one run, in an order the applier can follow:
/// containers before their members, parents before children.
final class ImportPlan {
  const ImportPlan(this.ops);

  final List<ImportOp> ops;

  bool get isEmpty => ops.isEmpty;
  int get length => ops.length;
}

/// Created / updated / unchanged for one entity kind.
final class KindCounts {
  const KindCounts({this.created = 0, this.updated = 0, this.unchanged = 0});

  final int created;
  final int updated;
  final int unchanged;

  int get total => created + updated + unchanged;

  KindCounts _add({int created = 0, int updated = 0, int unchanged = 0}) =>
      KindCounts(
        created: this.created + created,
        updated: this.updated + updated,
        unchanged: this.unchanged + unchanged,
      );
}

/// What a run touched and what it could not carry over. Counts only —
/// safe to print, paste and attach.
final class ImportReport {
  const ImportReport({
    required this.areas,
    required this.tags,
    required this.projects,
    required this.headings,
    required this.tasks,
    required this.unsupported,
    required this.notes,
  });

  final KindCounts areas;
  final KindCounts tags;
  final KindCounts projects;
  final KindCounts headings;
  final KindCounts tasks;

  /// Things features the import skipped or flattened, by name, with how
  /// many rows each affected. Buckets with zero rows are omitted.
  final Map<String, int> unsupported;

  /// Fixed mapping notes that hold for every run.
  final List<String> notes;

  /// The report as text lines; the caller adds the header (path,
  /// version, timing, dry-run).
  List<String> render() {
    String row(String kind, KindCounts c) =>
        '  $kind: ${c.created} created, ${c.updated} updated, '
        '${c.unchanged} unchanged';
    return [
      'imported',
      row('areas', areas),
      row('tags', tags),
      row('projects', projects),
      row('headings', headings),
      row('tasks', tasks),
      if (unsupported.isNotEmpty) 'not imported',
      for (final entry in unsupported.entries) '  ${entry.key}: ${entry.value}',
      if (notes.isNotEmpty) 'notes',
      for (final note in notes) '  $note',
    ];
  }
}

/// Names of the [ImportReport.unsupported] buckets.
abstract final class Unsupported {
  static const trashed = 'trashed items (not imported)';
  static const finishedProjects =
      'completed or cancelled projects (no project completion in v0.1)';
  static const inFinishedProjects = 'tasks and headings in those projects';
  static const inTemplateProjects =
      'tasks and headings in repeating template projects';
  static const movedHeadings =
      'headings moved to another project (their tasks keep the project; '
      'sai has no heading move)';
  static const repeatingTemplates =
      'repeating templates (instances import as plain tasks)';
  static const reminders = 'reminder times';
  static const evening = 'This Evening placement';
  static const contacts = 'assigned contacts';
  static const tagShortcuts = 'tag shortcuts';
  static const areaTags = 'area tags';
  static const anytimeUnfiled =
      'Anytime tasks without a date or a place (sai shows them in Inbox)';
  static const danglingParents =
      'references to a missing area, project or heading (imported unfiled)';
  static const headingWithoutProject =
      'headings without a live project (their tasks keep the project)';
  static const deletedInSai = 'entities deleted in sai since a previous import';
  static const badDates = 'unreadable dates (imported without the date)';
  static const futureInstants =
      'timestamps in the future (imported with the run time)';
  static const emptyTitles = 'empty titles (imported as "$untitled")';

  /// What an entity with no title is called in sai, which refuses an
  /// empty one.
  static const untitled = '(untitled)';
}

/// Plans the import of [snapshot] against [projection].
///
/// [now] bounds every carried-over instant: the archive refuses a
/// `created_at` or `at` later than the event's own timestamp, so anything
/// in the future is dropped and counted instead of failing the run.
(ImportPlan, ImportReport) planThingsImport(
  ThingsSnapshot snapshot, {
  required TaskProjection projection,
  required DateTime now,
}) => _Planner(snapshot, projection, now).plan();

final class _Planner {
  _Planner(this.snapshot, this.projection, this.now);

  final ThingsSnapshot snapshot;
  final TaskProjection projection;
  final DateTime now;

  final ops = <ImportOp>[];
  final unsupported = <String, int>{};
  var areas = const KindCounts();
  var tags = const KindCounts();
  var projects = const KindCounts();
  var headings = const KindCounts();
  var tasks = const KindCounts();

  /// Things uuids that will exist in sai after this run (already known,
  /// or created by an earlier operation of this plan).
  final _live = <String>{};

  void _count(String bucket, [int by = 1]) {
    if (by == 0) return;
    unsupported[bucket] = (unsupported[bucket] ?? 0) + by;
  }

  BlobRef? _idOf(String uuid) =>
      projection.idByExternal(ExternalSystems.things3, uuid);

  /// The instant, or null (counted) when it is later than [now].
  DateTime? _instant(double? seconds) {
    final at = decodeThingsInstant(seconds);
    if (at == null) return null;
    if (at.isAfter(now)) {
      _count(Unsupported.futureInstants);
      return null;
    }
    return at;
  }

  CalendarDate? _day(int? packed) {
    try {
      return decodeThingsDay(packed);
    } on FormatException {
      _count(Unsupported.badDates);
      return null;
    }
  }

  /// sai refuses an empty title; Things allows one.
  String _title(String title) {
    if (title.isNotEmpty) return title;
    _count(Unsupported.emptyTitles);
    return Unsupported.untitled;
  }

  TaskWhen _when(ThingsItem item) {
    if (item.start == ThingsStart.someday) return TaskWhen.someday;
    final date = _day(item.startDate);
    return date == null ? TaskWhen.none : TaskWhen.date(date);
  }

  (ImportPlan, ImportReport) plan() {
    _planAreas();
    _planTags();
    final liveProjects = _planProjects();
    final liveHeadings = _planHeadings(liveProjects);
    _planTasks(liveProjects, liveHeadings);
    return (
      ImportPlan(List.unmodifiable(ops)),
      ImportReport(
        areas: areas,
        tags: tags,
        projects: projects,
        headings: headings,
        tasks: tasks,
        unsupported: Map.unmodifiable(unsupported),
        notes: const [
          'Today order and manual order inside lists are not carried over; '
              'imported tasks follow Things\' structural order.',
          'A project\'s Someday does not propagate to its tasks (sai list '
              'rules).',
        ],
      ),
    );
  }

  void _planAreas() {
    for (final area in snapshot.areas) {
      _count(Unsupported.areaTags, snapshot.areaTags[area.uuid]?.length ?? 0);
      final title = _title(area.title);
      final id = _idOf(area.uuid);
      if (id == null) {
        ops.add(CreateArea(uuid: area.uuid, title: title, createdAt: null));
        areas = areas._add(created: 1);
      } else {
        final existing = projection.areas[id];
        if (existing == null || existing.deletedAt != null) {
          _count(Unsupported.deletedInSai);
          continue;
        }
        if (existing.title != title) {
          ops.add(EditArea(uuid: area.uuid, id: id, title: title));
          areas = areas._add(updated: 1);
        } else {
          areas = areas._add(unchanged: 1);
        }
      }
      _live.add(area.uuid);
    }
  }

  void _planTags() {
    final byUuid = {for (final t in snapshot.tags) t.uuid: t};
    // Parents before children; a parent Things does not know is dropped.
    final pending = [...snapshot.tags];
    final done = <String>{};
    while (pending.isNotEmpty) {
      final before = pending.length;
      pending.removeWhere((tag) {
        final parent = tag.parent;
        if (parent != null &&
            byUuid.containsKey(parent) &&
            !done.contains(parent)) {
          return false;
        }
        _planTag(
          tag,
          parentKnown: parent != null && byUuid.containsKey(parent),
        );
        done.add(tag.uuid);
        return true;
      });
      if (pending.length == before) {
        // A cycle; import the rest without parents.
        for (final tag in pending) {
          _planTag(tag, parentKnown: false);
        }
        break;
      }
    }
  }

  void _planTag(ThingsTag tag, {required bool parentKnown}) {
    if (tag.shortcut != null && tag.shortcut!.isNotEmpty) {
      _count(Unsupported.tagShortcuts);
    }
    final parent = parentKnown && _live.contains(tag.parent)
        ? tag.parent
        : null;
    final title = _title(tag.title);
    final id = _idOf(tag.uuid);
    if (id == null) {
      ops.add(
        CreateTag(
          uuid: tag.uuid,
          title: title,
          parent: parent,
          createdAt: null,
        ),
      );
      tags = tags._add(created: 1);
    } else {
      final existing = projection.tags[id];
      if (existing == null || existing.deletedAt != null) {
        _count(Unsupported.deletedInSai);
        return;
      }
      final parentId = parent == null ? null : _idOf(parent);
      final parentDiffers = parent == null
          ? existing.parent != null
          : existing.parent == null || existing.parent != parentId;
      final op = EditTag(
        uuid: tag.uuid,
        id: id,
        title: existing.title != title ? Patch(title) : null,
        parent: parentDiffers ? Patch(parent) : null,
      );
      if (op.title != null || op.parent != null) {
        ops.add(op);
        tags = tags._add(updated: 1);
      } else {
        tags = tags._add(unchanged: 1);
      }
    }
    _live.add(tag.uuid);
  }

  /// Tag uuids of [uuid] that exist after this run, in Things order.
  List<String> _tagsOf(String uuid) => [
    for (final tag in snapshot.taskTags[uuid] ?? const <String>[])
      if (_live.contains(tag)) tag,
  ];

  /// Whether [existing] (sai ids) already equals [wanted] (Things uuids).
  bool _sameTags(List<TagId> existing, List<String> wanted) {
    if (existing.length != wanted.length) return false;
    for (var i = 0; i < wanted.length; i++) {
      final id = _idOf(wanted[i]);
      if (id == null || existing[i] != id) return false;
    }
    return true;
  }

  /// Plans projects and returns the uuids that are live afterwards.
  Set<String> _planProjects() {
    final live = <String>{};
    for (final item in snapshot.items) {
      if (item.type != ThingsItemType.project) continue;
      if (item.trashed) {
        _count(Unsupported.trashed);
        continue;
      }
      if (item.status != ThingsStatus.open) {
        _count(Unsupported.finishedProjects);
        continue;
      }
      if (item.isRepeatingTemplate) {
        _count(Unsupported.repeatingTemplates);
        continue;
      }
      _noteFlags(item);
      final area = item.area != null && _live.contains(item.area)
          ? item.area
          : null;
      if (item.area != null && area == null) {
        _count(Unsupported.danglingParents);
      }
      final when = _when(item);
      final deadline = _day(item.deadline);
      final wantedTags = _tagsOf(item.uuid);
      final title = _title(item.title);
      final id = _idOf(item.uuid);
      if (id == null) {
        ops.add(
          CreateProject(
            uuid: item.uuid,
            title: title,
            notes: item.notes,
            area: area,
            when: when,
            deadline: deadline,
            tags: wantedTags,
            createdAt: _instant(item.creationDate),
          ),
        );
        projects = projects._add(created: 1);
      } else {
        final existing = projection.projects[id];
        if (existing == null || existing.deletedAt != null) {
          _count(Unsupported.deletedInSai);
          continue;
        }
        final areaId = area == null ? null : _idOf(area);
        final areaDiffers = area == null
            ? existing.area != null
            : existing.area == null || existing.area != areaId;
        final op = EditProject(
          uuid: item.uuid,
          id: id,
          title: existing.title != title ? Patch(title) : null,
          notes: existing.notes != item.notes ? Patch(item.notes) : null,
          area: areaDiffers ? Patch(area) : null,
          when: existing.when != when ? Patch(when) : null,
          deadline: existing.deadline != deadline ? Patch(deadline) : null,
          tags: _sameTags(existing.tags, wantedTags) ? null : Patch(wantedTags),
        );
        if (op.fields.isNotEmpty) {
          ops.add(op);
          projects = projects._add(updated: 1);
        } else {
          projects = projects._add(unchanged: 1);
        }
      }
      _live.add(item.uuid);
      live.add(item.uuid);
    }
    return live;
  }

  /// Plans headings and returns uuid → project uuid for the live ones.
  Map<String, String> _planHeadings(Set<String> liveProjects) {
    final live = <String, String>{};
    for (final item in snapshot.items) {
      if (item.type != ThingsItemType.heading) continue;
      if (item.trashed) {
        _count(Unsupported.trashed);
        continue;
      }
      final project = item.project;
      if (project == null || !liveProjects.contains(project)) {
        _count(
          _skippedProjectBucket(project) ?? Unsupported.headingWithoutProject,
        );
        continue;
      }
      final title = _title(item.title);
      final id = _idOf(item.uuid);
      if (id == null) {
        ops.add(
          CreateHeading(
            uuid: item.uuid,
            project: project,
            title: title,
            createdAt: _instant(item.creationDate),
          ),
        );
        headings = headings._add(created: 1);
      } else {
        final existing = projection.headings[id];
        if (existing == null || existing.deletedAt != null) {
          _count(Unsupported.deletedInSai);
          continue;
        }
        if (existing.project != _idOf(project)) {
          // sai has no heading.move: the sai heading stays where it was
          // and is not the target of any task this run; tasks under the
          // Things heading fall back to their (new) project.
          _count(Unsupported.movedHeadings);
          continue;
        }
        if (existing.title != title) {
          ops.add(EditHeading(uuid: item.uuid, id: id, title: title));
          headings = headings._add(updated: 1);
        } else {
          headings = headings._add(unchanged: 1);
        }
      }
      _live.add(item.uuid);
      live[item.uuid] = project;
    }
    return live;
  }

  late final _finishedProjects = {
    for (final item in snapshot.items)
      if (item.type == ThingsItemType.project &&
          !item.trashed &&
          item.status != ThingsStatus.open)
        item.uuid,
  };

  late final _templateProjects = {
    for (final item in snapshot.items)
      if (item.type == ThingsItemType.project &&
          !item.trashed &&
          item.status == ThingsStatus.open &&
          item.isRepeatingTemplate)
        item.uuid,
  };

  /// The bucket for an item whose project was skipped on purpose, or
  /// null when the project is simply missing or trashed.
  String? _skippedProjectBucket(String? project) {
    if (project == null) return null;
    if (_finishedProjects.contains(project)) {
      return Unsupported.inFinishedProjects;
    }
    if (_templateProjects.contains(project)) {
      return Unsupported.inTemplateProjects;
    }
    return null;
  }

  void _noteFlags(ThingsItem item) {
    if (item.reminderTime != null) _count(Unsupported.reminders);
    if (item.startBucket != 0) _count(Unsupported.evening);
    if (item.contact != null) _count(Unsupported.contacts);
  }

  void _planTasks(Set<String> liveProjects, Map<String, String> liveHeadings) {
    for (final item in snapshot.items) {
      if (item.type != ThingsItemType.task) continue;
      if (item.trashed) {
        _count(Unsupported.trashed);
        continue;
      }
      if (item.isRepeatingTemplate) {
        _count(Unsupported.repeatingTemplates);
        continue;
      }
      final skipped = _skippedProjectBucket(item.project);
      if (skipped != null) {
        _count(skipped);
        continue;
      }
      _noteFlags(item);
      final placement = _placement(item, liveProjects, liveHeadings);
      final when = _when(item);
      final deadline = _day(item.deadline);
      final wantedTags = _tagsOf(item.uuid);
      final checklist = _checklist(item);
      final status = _status(item);
      final title = _title(item.title);
      if (item.start == ThingsStart.anytime &&
          when == TaskWhen.none &&
          placement.area == null &&
          placement.project == null) {
        _count(Unsupported.anytimeUnfiled);
      }
      final id = _idOf(item.uuid);
      if (id == null) {
        ops.add(
          CreateTask(
            uuid: item.uuid,
            title: title,
            notes: item.notes,
            when: when,
            deadline: deadline,
            placement: placement,
            tags: wantedTags,
            checklist: checklist,
            status: status,
            createdAt: _instant(item.creationDate),
            instance: item.repeatingTemplate,
          ),
        );
        tasks = tasks._add(created: 1);
        continue;
      }
      final existing = projection.tasks[id];
      if (existing == null || existing.deletedAt != null) {
        _count(Unsupported.deletedInSai);
        continue;
      }
      var changed = false;
      final edit = EditTask(
        uuid: item.uuid,
        id: id,
        title: existing.title != title ? Patch(title) : null,
        notes: existing.notes != item.notes ? Patch(item.notes) : null,
        when: existing.when != when ? Patch(when) : null,
        deadline: existing.deadline != deadline ? Patch(deadline) : null,
        tags: _sameTags(existing.tags, wantedTags) ? null : Patch(wantedTags),
      );
      if (edit.fields.isNotEmpty) {
        ops.add(edit);
        changed = true;
      }
      if (!_samePlacement(existing, placement)) {
        ops.add(MoveTask(uuid: item.uuid, id: id, placement: placement));
        changed = true;
      }
      if (!status.matches(existing)) {
        ops.add(SetTaskStatus(uuid: item.uuid, id: id, status: status));
        changed = true;
      }
      if (!_sameChecklist(existing.checklist, checklist)) {
        ops.add(SetTaskChecklist(uuid: item.uuid, id: id, items: checklist));
        changed = true;
      }
      tasks = changed ? tasks._add(updated: 1) : tasks._add(unchanged: 1);
    }
  }

  ImportPlacement _placement(
    ThingsItem item,
    Set<String> liveProjects,
    Map<String, String> liveHeadings,
  ) {
    final heading = item.heading;
    if (heading != null) {
      final project = liveHeadings[heading];
      if (project != null) {
        return ImportPlacement(project: project, heading: heading);
      }
      // A dropped heading: fall back to the task's own project.
    }
    final project = item.project;
    if (project != null) {
      if (liveProjects.contains(project)) {
        return ImportPlacement(project: project);
      }
      _count(Unsupported.danglingParents);
      return const ImportPlacement();
    }
    final area = item.area;
    if (area != null) {
      if (_live.contains(area)) return ImportPlacement(area: area);
      _count(Unsupported.danglingParents);
    }
    return const ImportPlacement();
  }

  bool _samePlacement(Task existing, ImportPlacement wanted) {
    BlobRef? want(String? uuid) => uuid == null ? null : _idOf(uuid);
    bool same(BlobRef? have, String? uuid) =>
        uuid == null ? have == null : have != null && have == want(uuid);
    return same(existing.area, wanted.area) &&
        same(existing.project, wanted.project) &&
        same(existing.heading, wanted.heading);
  }

  ImportStatus _status(ThingsItem item) => switch (item.status) {
    ThingsStatus.open => const ImportStatus.open(),
    ThingsStatus.completed => ImportStatus.completed(_instant(item.stopDate)),
    ThingsStatus.cancelled => ImportStatus.cancelled(_instant(item.stopDate)),
  };

  List<ChecklistItem> _checklist(ThingsItem item) => [
    for (final entry in snapshot.checklistItems)
      if (entry.task == item.uuid)
        ChecklistItem(
          title: _title(entry.title),
          completedAt: entry.status == ThingsStatus.open
              ? null
              : _instant(entry.stopDate) ?? _instant(item.creationDate) ?? now,
        ),
  ];

  bool _sameChecklist(List<ChecklistItem> a, List<ChecklistItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].title != b[i].title || a[i].completedAt != b[i].completedAt) {
        return false;
      }
    }
    return true;
  }
}
