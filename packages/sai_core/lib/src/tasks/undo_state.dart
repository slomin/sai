import 'model.dart';

/// The slice of the projection an inverse is computed against — what
/// [TaskEvent.invert] may read, and nothing more. `TaskProjection` is the
/// one implementation; the interface exists so the event definitions can
/// invert themselves without importing the projection that applies them.
abstract interface class UndoState {
  Map<TaskId, Task> get tasks;
  Map<ProjectId, Project> get projects;
  Map<HeadingId, Heading> get headings;
  Map<AreaId, Area> get areas;
  Map<TagId, Tag> get tags;

  /// The prior live sibling in [task]'s structural group, for an inverse
  /// move. Null means the task was first.
  TaskId? structuralPredecessor(TaskId task);

  /// The prior task in Today's independent sequence, for an inverse
  /// reorder. Null means the task was first.
  TaskId? todayPredecessor(TaskId task);

  /// The prior live area in the sidebar's sequence, for an inverse
  /// reorder. Null means the area was first.
  AreaId? areaPredecessor(AreaId area);

  /// The prior live project in [project]'s group — its live area, or the
  /// standalone group. Null means it was first.
  ProjectId? projectPredecessor(ProjectId project);

  /// The prior live heading of [heading]'s project. Null means first.
  HeadingId? headingPredecessor(HeadingId heading);
}
