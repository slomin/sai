/// The two ways Things 3 stores time.
///
/// A calendar day (`startDate`, `deadline`) is one integer with the year,
/// month and day packed into bit fields — `year << 16 | month << 12 |
/// day << 7` — and no zone, which maps onto [CalendarDate] without
/// guessing. An instant (`creationDate`, `stopDate`,
/// `userModificationDate`) is Unix seconds in UTC as a REAL.
///
/// Verified against Things 3.23.1 (and 3.22.12, same schema).
library;

import '../tasks/date.dart';

/// Decodes a packed Things day; `null` and `0` are "no date".
///
/// Throws a [FormatException] naming the raw value when the fields do not
/// form a real date — the value, never a title, so the message is safe to
/// show.
CalendarDate? decodeThingsDay(int? packed) {
  if (packed == null || packed == 0) return null;
  final year = packed >> 16;
  final month = (packed >> 12) & 0xF;
  final day = (packed >> 7) & 0x1F;
  final normalized = DateTime.utc(year, month, day);
  if (normalized.year != year ||
      normalized.month != month ||
      normalized.day != day) {
    throw FormatException('not a Things day: $packed');
  }
  return CalendarDate(year, month, day);
}

/// Packs a [CalendarDate] the way Things does — the inverse of
/// [decodeThingsDay], used by the fixture builder in tests.
int encodeThingsDay(CalendarDate date) =>
    date.year << 16 | date.month << 12 | date.day << 7;

/// Decodes Unix seconds (a REAL) into a UTC instant with microsecond
/// precision; `null` is "no instant".
DateTime? decodeThingsInstant(num? seconds) {
  if (seconds == null) return null;
  return DateTime.fromMicrosecondsSinceEpoch(
    (seconds * Duration.microsecondsPerSecond).round(),
    isUtc: true,
  );
}
