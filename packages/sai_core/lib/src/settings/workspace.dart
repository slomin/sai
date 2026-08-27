import 'dart:collection';

/// Where the workspace was left (#76): identifiers and UI preferences only
/// — never task text, never a secret. Read leniently: a member this sai
/// cannot use is dropped rather than a reason to refuse the file, because
/// losing a restored view is cheap and losing the provider settings is
/// not. The clients validate the ids against the projection before use.
final class WorkspaceState {
  const WorkspaceState({
    this.section,
    this.task,
    this.collapsedAreas = const [],
    this.assistantVisible,
  });

  /// Nothing remembered; what a fresh file reads as, and what is omitted.
  static const empty = WorkspaceState();

  /// The selected section's key (`sectionKey`), or null.
  final String? section;

  /// The selected task's id, or null.
  final String? task;

  /// The ids of the areas whose projects are folded away in the sidebar.
  final List<String> collapsedAreas;

  /// Whether the assistant pane is shown; null leaves the client's default.
  final bool? assistantVisible;

  bool get isEmpty =>
      section == null &&
      task == null &&
      collapsedAreas.isEmpty &&
      assistantVisible == null;

  /// Reads the `workspace` value of a settings object: anything but an
  /// object is [empty], and inside it a member of the wrong type is
  /// dropped, a list entry that is not a string skipped.
  static WorkspaceState fromJson(Object? json) {
    if (json is! Map<String, Object?>) return empty;
    final section = json['section'];
    final task = json['task'];
    final collapsed = json['collapsed_areas'];
    final assistant = json['assistant_visible'];
    return WorkspaceState(
      section: section is String && section.isNotEmpty ? section : null,
      task: task is String && task.isNotEmpty ? task : null,
      collapsedAreas: [
        if (collapsed is List)
          for (final entry in collapsed)
            if (entry is String && entry.isNotEmpty) entry,
      ],
      assistantVisible: assistant is bool ? assistant : null,
    );
  }

  /// The `workspace` value, keys sorted, defaults omitted.
  Map<String, Object?> toJson() => SplayTreeMap<String, Object?>.of({
    'section': ?section,
    'task': ?task,
    if (collapsedAreas.isNotEmpty) 'collapsed_areas': collapsedAreas,
    'assistant_visible': ?assistantVisible,
  });

  @override
  bool operator ==(Object other) =>
      other is WorkspaceState &&
      other.section == section &&
      other.task == task &&
      other.assistantVisible == assistantVisible &&
      other.collapsedAreas.length == collapsedAreas.length &&
      _sameEntries(other.collapsedAreas, collapsedAreas);

  @override
  int get hashCode => Object.hash(
    section,
    task,
    assistantVisible,
    Object.hashAll(collapsedAreas),
  );

  @override
  String toString() => 'WorkspaceState(${toJson()})';
}

bool _sameEntries(List<String> a, List<String> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
