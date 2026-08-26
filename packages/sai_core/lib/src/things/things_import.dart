/// The applier: walks an [ImportPlan] through [TaskStore] as the `system`
/// actor, resolving Things uuids to sai ids as creates return them.
/// Every write is an ordinary task-domain event carrying `external`, so
/// the projection's index finds it on the next run; being `system`, the
/// run is an undo barrier rather than a hundred undo entries.
library;

import '../archive/blobref.dart';
import '../tasks/events.dart';
import '../tasks/model.dart';
import '../tasks/store.dart';
import 'things_db.dart';
import 'things_mapping.dart';

/// What one run did.
final class ThingsImportResult {
  const ThingsImportResult({
    required this.plan,
    required this.report,
    required this.eventsAppended,
    required this.dryRun,
  });

  final ImportPlan plan;
  final ImportReport report;

  /// Archive lines written; always 0 for a dry run.
  final int eventsAppended;
  final bool dryRun;
}

/// A [MoveTask] or [SetTaskStatus] the store refused; the run stops at
/// the first one so a half-applied plan is visible, not silent.
final class ThingsImportException implements Exception {
  ThingsImportException(this.op, this.cause);

  final ImportOp op;
  final Object cause;

  @override
  String toString() =>
      'ThingsImportException: ${op.runtimeType} for ${op.uuid}: $cause';
}

/// Plans and, unless [dryRun], applies the import of [snapshot] into
/// [store]. [now] bounds carried-over instants (see [planThingsImport]).
Future<ThingsImportResult> importThings(
  ThingsSnapshot snapshot, {
  required TaskStore store,
  required DateTime now,
  bool dryRun = false,
  ThingsImportOptions options = const ThingsImportOptions(),
}) async {
  final (plan, report) = planThingsImport(
    snapshot,
    projection: store.projection,
    now: now,
    options: options,
  );
  if (dryRun) {
    return ThingsImportResult(
      plan: plan,
      report: report,
      eventsAppended: 0,
      dryRun: true,
    );
  }
  final applier = _Applier(store, snapshot);
  for (final op in plan.ops) {
    try {
      await applier.apply(op);
    } on Object catch (error) {
      throw ThingsImportException(op, error);
    }
  }
  return ThingsImportResult(
    plan: plan,
    report: report,
    eventsAppended: applier.appended,
    dryRun: false,
  );
}

final class _Applier {
  _Applier(this.store, ThingsSnapshot snapshot) {
    final projection = store.projection;
    for (final uuid in [
      for (final a in snapshot.areas) a.uuid,
      for (final t in snapshot.tags) t.uuid,
      for (final i in snapshot.items) i.uuid,
    ]) {
      final id = projection.idByExternal(ExternalSystems.things3, uuid);
      if (id != null) ids[uuid] = id;
    }
  }

  final TaskStore store;
  final ids = <String, BlobRef>{};
  var appended = 0;

  static const _by = Attribution.system();

  ExternalRef _external(String uuid, {String? instance}) => ExternalRef(
    system: ExternalSystems.things3,
    id: uuid,
    version: thingsVerifiedVersion,
    instance: instance,
  );

  BlobRef _id(String uuid) =>
      ids[uuid] ?? (throw StateError('no sai id for Things $uuid'));

  BlobRef? _idOrNull(String? uuid) => uuid == null ? null : _id(uuid);

  List<BlobRef> _ids(List<String> uuids) => [for (final u in uuids) _id(u)];

  Future<void> apply(ImportOp op) async {
    switch (op) {
      case CreateArea():
        ids[op.uuid] = await store.createArea(
          title: op.title,
          createdAt: op.createdAt,
          external: _external(op.uuid),
          by: _by,
        );
      case EditArea():
        await store.editArea(op.id, title: Patch(op.title), by: _by);
      case CreateTag():
        ids[op.uuid] = await store.createTag(
          title: op.title,
          parent: _idOrNull(op.parent),
          createdAt: op.createdAt,
          external: _external(op.uuid),
          by: _by,
        );
      case EditTag():
        await store.editTag(
          op.id,
          title: op.title,
          parent: op.parent == null ? null : Patch(_idOrNull(op.parent!.value)),
          by: _by,
        );
      case CreateProject():
        ids[op.uuid] = await store.createProject(
          title: op.title,
          notes: op.notes,
          area: _idOrNull(op.area),
          when: op.when,
          deadline: op.deadline,
          tags: _ids(op.tags),
          createdAt: op.createdAt,
          external: _external(op.uuid),
          by: _by,
        );
      case EditProject():
        await store.editProject(
          op.id,
          title: op.title,
          notes: op.notes,
          area: op.area == null ? null : Patch(_idOrNull(op.area!.value)),
          when: op.when,
          deadline: op.deadline,
          tags: op.tags == null ? null : Patch(_ids(op.tags!.value)),
          by: _by,
        );
      case CreateHeading():
        ids[op.uuid] = await store.createHeading(
          project: _id(op.project),
          title: op.title,
          createdAt: op.createdAt,
          external: _external(op.uuid),
          by: _by,
        );
      case EditHeading():
        await store.editHeading(op.id, title: Patch(op.title), by: _by);
      case CreateTask():
        final id = await store.createTask(
          title: op.title,
          notes: op.notes,
          when: op.when,
          deadline: op.deadline,
          project: _idOrNull(op.placement.project),
          area: _idOrNull(op.placement.area),
          heading: _idOrNull(op.placement.heading),
          tags: _ids(op.tags),
          checklist: op.checklist,
          createdAt: op.createdAt,
          external: _external(op.uuid, instance: op.instance),
          by: _by,
        );
        ids[op.uuid] = id;
        appended += 1 + await _setStatus(id, op.status);
        return;
      case EditTask():
        await store.editTask(
          op.id,
          title: op.title,
          notes: op.notes,
          when: op.when,
          deadline: op.deadline,
          tags: op.tags == null ? null : Patch(_ids(op.tags!.value)),
          by: _by,
        );
      case MoveTask():
        await store.moveTask(
          op.id,
          project: _idOrNull(op.placement.project),
          area: _idOrNull(op.placement.area),
          heading: _idOrNull(op.placement.heading),
          by: _by,
        );
      case SetTaskStatus():
        appended += await _setStatus(op.id, op.status, reopen: true);
        return;
      case SetTaskChecklist():
        await store.setChecklist(op.id, op.items, by: _by);
    }
    appended += 1;
  }

  /// Writes the completion/cancellation, or a reopen when [reopen] and
  /// the status is open; returns the number of events written.
  Future<int> _setStatus(
    BlobRef id,
    ImportStatus status, {
    bool reopen = false,
  }) async {
    switch (status.kind) {
      case ImportStatusKind.completed:
        await store.completeTask(id, at: status.at, by: _by);
        return 1;
      case ImportStatusKind.cancelled:
        await store.cancelTask(id, at: status.at, by: _by);
        return 1;
      case ImportStatusKind.open:
        if (!reopen) return 0;
        await store.reopenTask(id, by: _by);
        return 1;
    }
  }
}
