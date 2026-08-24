/// Undo as the archive demands it: never a rewrite, always a new event.
/// Every mutation's inverse is a single event of the same vocabulary,
/// computed against the projection the mutation was validated on — the
/// table `docs/tasks/task-model-v0.md` promises.
library;

import '../archive/blobref.dart';
import 'events.dart';
import 'model.dart';
import 'projection.dart';

/// The single event that puts the entity [event] touched back the way
/// [before] had it. [created] is the id the append minted — the entity id
/// for a `*.create`, unused otherwise.
///
/// Total over the whole vocabulary, so a session's undo stack holds
/// exactly one entry per command: a degenerate mutation (deleting the
/// already-deleted, reopening the open) inverts to the state-preserving
/// event of its kind rather than to nothing, and one undo press never
/// silently skips to an older mutation. State comes back, timestamps
/// only where they are state: completion and cancellation instants ride
/// in `at`, while `modifiedAt` bumps to the inverse's own ts and an
/// older `deletedAt` is gone.
///
/// Throws [StateError] when [before] does not hold the event's subject —
/// call it with the projection the event was validated against.
TaskEvent invertEvent(
  TaskEvent event,
  TaskProjection before, {
  required BlobRef created,
}) {
  switch (event) {
    case TaskCreated():
      return TaskDeleted(created);
    case TaskEdited():
      final prior = _prior(before.tasks[event.task], event.task);
      return TaskEdited(
        event.task,
        title: event.title == null ? null : Patch(prior.title),
        notes: event.notes == null ? null : Patch(prior.notes),
        when: event.when == null ? null : Patch(prior.when),
        deadline: event.deadline == null ? null : Patch(prior.deadline),
        tags: event.tags == null ? null : Patch(prior.tags),
      );
    case TaskMoved():
      final prior = _prior(before.tasks[event.task], event.task);
      return TaskMoved(
        event.task,
        project: prior.project,
        area: prior.area,
        heading: prior.heading,
      );
    case TaskCompleted(:final task) ||
        TaskCancelled(:final task) ||
        TaskReopened(:final task):
      final prior = _prior(before.tasks[task], task);
      if (prior.cancelledAt != null) {
        return TaskCancelled(task, at: prior.cancelledAt);
      }
      if (prior.completedAt != null) {
        return TaskCompleted(task, at: prior.completedAt);
      }
      return TaskReopened(task);
    case TaskDeleted(:final task) || TaskRestored(:final task):
      final prior = _prior(before.tasks[task], task);
      return prior.deletedAt == null ? TaskRestored(task) : TaskDeleted(task);
    case TaskChecklistSet():
      final prior = _prior(before.tasks[event.task], event.task);
      return TaskChecklistSet(event.task, prior.checklist);
    case AreaCreated():
      return AreaDeleted(created);
    case AreaEdited():
      final prior = _prior(before.areas[event.area], event.area);
      return AreaEdited(event.area, title: Patch(prior.title));
    case AreaDeleted(:final area) || AreaRestored(:final area):
      final prior = _prior(before.areas[area], area);
      return prior.deletedAt == null ? AreaRestored(area) : AreaDeleted(area);
    case ProjectCreated():
      return ProjectDeleted(created);
    case ProjectEdited():
      final prior = _prior(before.projects[event.project], event.project);
      return ProjectEdited(
        event.project,
        title: event.title == null ? null : Patch(prior.title),
        notes: event.notes == null ? null : Patch(prior.notes),
        area: event.area == null ? null : Patch(prior.area),
        when: event.when == null ? null : Patch(prior.when),
        deadline: event.deadline == null ? null : Patch(prior.deadline),
        tags: event.tags == null ? null : Patch(prior.tags),
      );
    case ProjectDeleted(:final project) || ProjectRestored(:final project):
      final prior = _prior(before.projects[project], project);
      return prior.deletedAt == null
          ? ProjectRestored(project)
          : ProjectDeleted(project);
    case HeadingCreated():
      return HeadingDeleted(created);
    case HeadingEdited():
      final prior = _prior(before.headings[event.heading], event.heading);
      return HeadingEdited(event.heading, title: Patch(prior.title));
    case HeadingDeleted(:final heading) || HeadingRestored(:final heading):
      final prior = _prior(before.headings[heading], heading);
      return prior.deletedAt == null
          ? HeadingRestored(heading)
          : HeadingDeleted(heading);
    case TagCreated():
      return TagDeleted(created);
    case TagEdited():
      final prior = _prior(before.tags[event.tag], event.tag);
      return TagEdited(
        event.tag,
        title: event.title == null ? null : Patch(prior.title),
        parent: event.parent == null ? null : Patch(prior.parent),
      );
    case TagDeleted(:final tag) || TagRestored(:final tag):
      final prior = _prior(before.tags[tag], tag);
      return prior.deletedAt == null ? TagRestored(tag) : TagDeleted(tag);
  }
}

T _prior<T>(T? entity, BlobRef id) =>
    entity ?? (throw StateError('nothing known about $id to invert against'));
