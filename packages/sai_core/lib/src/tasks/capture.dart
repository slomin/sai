/// Quick capture: one text line in, one Inbox-bound task out.
///
/// The grammar is fixed and tiny — trailing `@when` and `!deadline`
/// tokens, nothing else — and total: text the parser does not recognise
/// stays in the title, so no line is ever refused. The normative spec
/// lives in `docs/tasks/task-model-v0.md`.
library;

import 'date.dart';
import 'model.dart';

/// One captured line, parsed. [title] is never empty. Capture never
/// files: no project, area, heading or tag — an Inbox task is the point.
final class QuickCapture {
  const QuickCapture({
    required this.title,
    this.when = TaskWhen.none,
    this.deadline,
  });

  final String title;
  final TaskWhen when;
  final CalendarDate? deadline;

  @override
  bool operator ==(Object other) =>
      other is QuickCapture &&
      other.title == title &&
      other.when == when &&
      other.deadline == deadline;

  @override
  int get hashCode => Object.hash(title, when, deadline);

  @override
  String toString() => 'QuickCapture($title, when: $when, deadline: $deadline)';
}

/// Parses one quick-capture [line] against [today].
///
/// Trailing whitespace-separated tokens are consumed right to left —
/// `@today`, `@tomorrow`, `@someday` or `@YYYY-MM-DD` for the when,
/// `!today`, `!tomorrow` or `!YYYY-MM-DD` for the deadline — until the
/// first word that is no token, repeats a kind already taken, or is the
/// only word left (a token alone is a title, never an empty one). Never
/// throws; returns null when [line] is blank.
QuickCapture? parseQuickCapture(String line, {required CalendarDate today}) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return null;

  var rest = trimmed;
  TaskWhen? when;
  CalendarDate? deadline;
  while (true) {
    final cut = rest.lastIndexOf(_whitespace);
    final word = cut < 0 ? rest : rest.substring(cut + 1);
    if (word.startsWith('@') && when == null) {
      final day = _day(word.substring(1), today);
      if (day == null && !_isSomeday(word.substring(1))) break;
      when = day == null ? TaskWhen.someday : TaskWhen.date(day);
    } else if (word.startsWith('!')) {
      if (deadline != null) break;
      final day = _day(word.substring(1), today);
      if (day == null) break;
      deadline = day;
    } else {
      break;
    }
    if (cut < 0) {
      // Consuming the last word would leave no title: nothing was a
      // token after all, the whole trimmed line is the title.
      return QuickCapture(title: trimmed);
    }
    rest = rest.substring(0, cut).trimRight();
  }
  return QuickCapture(
    title: rest,
    when: when ?? TaskWhen.none,
    deadline: deadline,
  );
}

/// The line that would capture [task] again: its title plus the tokens
/// its when and deadline came from. With [today] given, today's and
/// tomorrow's dates render as `@today` / `@tomorrow`; without it, as
/// dates. Both clients render list rows through this.
String formatQuickCapture(Task task, {CalendarDate? today}) {
  final parts = [task.title];
  switch (task.when) {
    case TaskWhenNone():
      break;
    case TaskWhenSomeday():
      parts.add('@someday');
    case TaskWhenDate(:final date):
      parts.add('@${_dayText(date, today)}');
  }
  final deadline = task.deadline;
  if (deadline != null) parts.add('!${_dayText(deadline, today)}');
  return parts.join(' ');
}

final _whitespace = RegExp(r'\s');

bool _isSomeday(String keyword) => keyword.toLowerCase() == 'someday';

CalendarDate? _day(String keyword, CalendarDate today) =>
    switch (keyword.toLowerCase()) {
      'today' => today,
      'tomorrow' => today.addDays(1),
      _ => CalendarDate.tryParse(keyword),
    };

String _dayText(CalendarDate day, CalendarDate? today) {
  if (day == today) return 'today';
  if (today != null && day == today.addDays(1)) return 'tomorrow';
  return day.toString();
}
