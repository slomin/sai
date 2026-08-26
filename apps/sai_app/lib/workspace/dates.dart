import 'package:sai_core/sai_core.dart';

const _days = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _weekday(CalendarDate date) =>
    _days[DateTime(date.year, date.month, date.day).weekday - 1];

/// `Tuesday 25 August` — the headline eyebrow and a day group's label.
String longDay(CalendarDate date) =>
    '${_weekday(date)} ${date.day} ${_months[date.month - 1]}';

/// `Tue 25 Aug` — a chip.
String shortDay(CalendarDate date) =>
    '${_weekday(date).substring(0, 3)} ${date.day} '
    '${_months[date.month - 1].substring(0, 3)}';

/// A day group's label, with the relative word where it helps.
String dayGroupLabel(CalendarDate day, {required CalendarDate today}) {
  final relative = day == today
      ? ' · today'
      : day == today.addDays(1)
      ? ' · tomorrow'
      : '';
  return '${longDay(day)}$relative';
}

/// `18:22` — when a task was finished, in local time.
String clockTime(DateTime moment) {
  final local = moment.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}
