import 'package:sai_core/sai_core.dart';

import '../widgets/chip.dart';
import 'dates.dart';

/// One chip on a row: what it says and how it reads.
final class ChipSpec {
  const ChipSpec(this.text, this.tone);

  final String text;
  final ChipTone tone;

  @override
  bool operator ==(Object other) =>
      other is ChipSpec && other.text == text && other.tone == tone;

  @override
  int get hashCode => Object.hash(text, tone);

  @override
  String toString() => 'ChipSpec($text, $tone)';
}

/// The chips a task carries in [section], as the reference orders them:
/// a deadline (red once it is due), SOMEDAY when a due task surfaces in
/// Today, the container where the list does not already say it, tags,
/// checklist progress, and how a finished task ended.
List<ChipSpec> taskRowChips(
  Task task, {
  required CalendarDate today,
  required SidebarSection section,
  String? container,
  List<String> tags = const [],
}) {
  final chips = <ChipSpec>[];
  if (task.deadline case final deadline?) {
    chips.add(
      deadline <= today
          ? ChipSpec('DUE ${shortDay(deadline)}', ChipTone.due)
          : ChipSpec(shortDay(deadline), ChipTone.tonal),
    );
  }
  final list = section is ListSection ? section.list : null;
  if (task.when == TaskWhen.someday && list == TaskList.today) {
    chips.add(const ChipSpec('SOMEDAY', ChipTone.flat));
  }
  if (container != null &&
      (list == TaskList.today ||
          list == TaskList.inbox ||
          list == TaskList.logbook)) {
    chips.add(ChipSpec(container, ChipTone.flat));
  }
  for (final tag in tags) {
    chips.add(ChipSpec(tag, ChipTone.flat));
  }
  if (task.checklist.isNotEmpty) {
    final done = task.checklist.where((i) => i.completedAt != null).length;
    chips.add(ChipSpec('$done/${task.checklist.length}', ChipTone.tonal));
  }
  switch (task.status) {
    case TaskStatus.cancelled:
      chips.add(const ChipSpec('CANCELLED', ChipTone.flat));
    case TaskStatus.completed:
      chips.add(ChipSpec(clockTime(task.completedAt!), ChipTone.flat));
    case TaskStatus.open:
      break;
  }
  return chips;
}

/// The area or project a task is filed under, by title; null when unfiled.
String? containerLabel(TaskProjection projection, Task task) {
  if (task.project case final id?) {
    return projection.projects[id]?.title;
  }
  if (task.area case final id?) {
    return projection.areas[id]?.title;
  }
  return null;
}

/// The task's live tag titles, in its own order.
List<String> tagLabels(TaskProjection projection, Task task) => [
  for (final id in task.tags)
    if (projection.tags[id] case final tag? when tag.deletedAt == null)
      tag.title,
];
