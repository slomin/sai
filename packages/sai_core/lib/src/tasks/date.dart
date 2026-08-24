/// A calendar day — no time, no zone. `when` dates and deadlines are days
/// in the person's life, not instants: comparing an instant against "today"
/// invites off-by-a-timezone bugs this type makes unrepresentable.
///
/// JSON form: `"2026-08-24"`. Lexicographic order of the text form is
/// chronological.
final class CalendarDate implements Comparable<CalendarDate> {
  const CalendarDate(this.year, this.month, this.day);

  /// The calendar day of [moment] in the host's local zone — what "today"
  /// means to the person in front of the screen.
  factory CalendarDate.fromLocal(DateTime moment) {
    final local = moment.toLocal();
    return CalendarDate(local.year, local.month, local.day);
  }

  /// Parses the strict `YYYY-MM-DD` form.
  ///
  /// Rejects anything else — wrong width, separators, or a date that does
  /// not exist (`2026-02-30`) — with a [FormatException].
  factory CalendarDate.parse(String text) {
    final match = _form.firstMatch(text);
    if (match == null) {
      throw FormatException('not a calendar date (YYYY-MM-DD): "$text"');
    }
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    // DateTime.utc normalizes overflowing components (2026-02-30 becomes
    // March 2nd); a date is real iff normalization changes nothing.
    final normalized = DateTime.utc(year, month, day);
    if (normalized.year != year ||
        normalized.month != month ||
        normalized.day != day) {
      throw FormatException('not a real date: "$text"');
    }
    return CalendarDate(year, month, day);
  }

  /// Like [CalendarDate.parse], but returns null instead of throwing.
  static CalendarDate? tryParse(String text) {
    try {
      return CalendarDate.parse(text);
    } on FormatException {
      return null;
    }
  }

  static final _form = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

  final int year;
  final int month;
  final int day;

  /// This day shifted by [days], which may be negative.
  CalendarDate addDays(int days) {
    final shifted = DateTime.utc(year, month, day + days);
    return CalendarDate(shifted.year, shifted.month, shifted.day);
  }

  bool operator <(CalendarDate other) => compareTo(other) < 0;
  bool operator <=(CalendarDate other) => compareTo(other) <= 0;
  bool operator >(CalendarDate other) => compareTo(other) > 0;
  bool operator >=(CalendarDate other) => compareTo(other) >= 0;

  @override
  int compareTo(CalendarDate other) {
    if (year != other.year) return year.compareTo(other.year);
    if (month != other.month) return month.compareTo(other.month);
    return day.compareTo(other.day);
  }

  /// The JSON form: `"2026-08-24"`.
  String toJson() => toString();

  @override
  String toString() {
    String pad(int n, int width) => n.toString().padLeft(width, '0');
    return '${pad(year, 4)}-${pad(month, 2)}-${pad(day, 2)}';
  }

  @override
  bool operator ==(Object other) =>
      other is CalendarDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);
}
