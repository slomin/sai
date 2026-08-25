import 'package:nocterm/nocterm.dart';
import 'package:sai_core/sai_core.dart';

/// The lists (#41): the capture sections as rows, one task selectable.
///
/// Headers are not selectable; the cursor is an index into [rows], the
/// tasks in display order. The caller owns the index and clamps it with
/// [clamp] whenever the projection changes, so a completed task leaves
/// the cursor on the row that took its place.
class TaskListPane extends StatelessComponent {
  const TaskListPane({
    super.key,
    required this.sections,
    required this.today,
    required this.selected,
    required this.scroll,
  });

  final List<CaptureSection> sections;
  final CalendarDate today;

  /// Index into [rows]; anything out of range selects nothing.
  final int selected;
  final ScrollController scroll;

  /// The marker on the selected row.
  static const marker = '› ';

  /// Every task in the order the rows show them.
  static List<Task> rows(List<CaptureSection> sections) => [
    for (final section in sections) ...section.tasks,
  ];

  /// [index] kept inside a list of [count] rows (-1 when there are none).
  static int clamp(int index, int count) =>
      count == 0 ? -1 : index.clamp(0, count - 1);

  /// The screen row (headers included) of the [selected]th task, for
  /// [ScrollController.ensureIndexVisible]; -1 when nothing is selected.
  static int screenRow(List<CaptureSection> sections, int selected) {
    var row = 0;
    var task = 0;
    for (final section in sections) {
      row++;
      for (final _ in section.tasks) {
        if (task == selected) return row;
        row++;
        task++;
      }
    }
    return -1;
  }

  @override
  Component build(BuildContext context) {
    final lines = <Component>[];
    var task = 0;
    for (final section in sections) {
      lines.add(Text(section.label));
      for (final entry in section.tasks) {
        final line = formatQuickCapture(entry, today: today);
        lines.add(
          task == selected
              ? Text('$marker$line', style: const TextStyle(reverse: true))
              : Text('  $line'),
        );
        task++;
      }
    }
    return ListView.builder(
      controller: scroll,
      itemExtent: 1,
      itemCount: lines.length,
      itemBuilder: (context, index) => lines[index],
    );
  }
}
