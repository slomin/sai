import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  group('CalendarDate.parse', () {
    test('parses a well-formed date', () {
      final date = CalendarDate.parse('2026-08-24');
      expect(date.year, 2026);
      expect(date.month, 8);
      expect(date.day, 24);
    });

    test('rejects everything that is not exactly YYYY-MM-DD', () {
      for (final text in [
        '',
        '2026-8-4',
        '26-08-04',
        '2026/08/24',
        '2026-08-24T00:00:00Z',
        ' 2026-08-24',
        '2026-08-24 ',
      ]) {
        expect(
          () => CalendarDate.parse(text),
          throwsFormatException,
          reason: '"$text" must be rejected',
        );
      }
    });

    test('rejects dates that do not exist', () {
      for (final text in [
        '2026-13-01',
        '2026-00-10',
        '2026-02-30',
        '2026-04-31',
        '2026-01-00',
      ]) {
        expect(
          () => CalendarDate.parse(text),
          throwsFormatException,
          reason: '"$text" must be rejected',
        );
      }
      // 2028 is a leap year, 2026 is not.
      expect(CalendarDate.parse('2028-02-29').day, 29);
      expect(() => CalendarDate.parse('2026-02-29'), throwsFormatException);
    });

    test('tryParse mirrors parse without throwing', () {
      expect(CalendarDate.tryParse('2026-08-24'), CalendarDate(2026, 8, 24));
      expect(CalendarDate.tryParse('2026-02-30'), isNull);
    });
  });

  group('JSON and text form', () {
    test('toJson round-trips through parse', () {
      const date = CalendarDate(2026, 8, 24);
      expect(date.toJson(), '2026-08-24');
      expect(CalendarDate.parse(date.toJson()), date);
    });

    test('toString equals toJson and pads to fixed width', () {
      expect(const CalendarDate(2026, 1, 2).toString(), '2026-01-02');
      expect(const CalendarDate(999, 12, 31).toString(), '0999-12-31');
    });

    test('lexicographic order of the text form is chronological', () {
      final dates = [
        const CalendarDate(2025, 12, 31),
        const CalendarDate(2026, 1, 1),
        const CalendarDate(2026, 1, 2),
        const CalendarDate(2026, 8, 24),
        const CalendarDate(2026, 11, 3),
      ];
      final texts = dates.map((d) => d.toString()).toList();
      expect(texts, List.of(texts)..sort());
    });
  });

  group('value semantics', () {
    test('equality and hashCode', () {
      expect(const CalendarDate(2026, 8, 24), CalendarDate(2026, 8, 24));
      expect(
        const CalendarDate(2026, 8, 24).hashCode,
        CalendarDate(2026, 8, 24).hashCode,
      );
      expect(
        const CalendarDate(2026, 8, 24),
        isNot(const CalendarDate(2026, 8, 25)),
      );
    });

    test('usable as a map key', () {
      final map = {const CalendarDate(2026, 8, 24): 'today'};
      expect(map[CalendarDate(2026, 8, 24)], 'today');
    });
  });

  group('comparisons', () {
    test('compareTo and the operators agree with chronology', () {
      const a = CalendarDate(2026, 8, 23);
      const b = CalendarDate(2026, 8, 24);
      expect(a.compareTo(b), isNegative);
      expect(b.compareTo(a), isPositive);
      expect(a.compareTo(CalendarDate(2026, 8, 23)), 0);
      expect(a < b, isTrue);
      expect(a <= b, isTrue);
      expect(a <= CalendarDate(2026, 8, 23), isTrue);
      expect(b > a, isTrue);
      expect(b >= b, isTrue);
      expect(a > b, isFalse);
    });
  });

  group('addDays', () {
    test('crosses month, year and leap boundaries', () {
      expect(
        const CalendarDate(2026, 1, 31).addDays(1),
        const CalendarDate(2026, 2, 1),
      );
      expect(
        const CalendarDate(2026, 12, 31).addDays(1),
        const CalendarDate(2027, 1, 1),
      );
      expect(
        const CalendarDate(2028, 2, 28).addDays(1),
        const CalendarDate(2028, 2, 29),
      );
      expect(
        const CalendarDate(2026, 2, 28).addDays(1),
        const CalendarDate(2026, 3, 1),
      );
      expect(
        const CalendarDate(2026, 8, 24).addDays(-1),
        const CalendarDate(2026, 8, 23),
      );
      expect(
        const CalendarDate(2026, 8, 24).addDays(0),
        const CalendarDate(2026, 8, 24),
      );
    });
  });

  group('fromLocal', () {
    test('takes the local calendar day, not the UTC one', () {
      // 23:30 local on the 24th: the local day is the 24th regardless of
      // what UTC day that instant falls on.
      final lateEvening = DateTime(2026, 8, 24, 23, 30);
      expect(CalendarDate.fromLocal(lateEvening), CalendarDate(2026, 8, 24));
      final earlyMorning = DateTime(2026, 8, 24, 0, 15);
      expect(CalendarDate.fromLocal(earlyMorning), CalendarDate(2026, 8, 24));
    });

    test('converts a UTC instant to the local day first', () {
      final utc = DateTime.utc(2026, 8, 24, 12);
      expect(
        CalendarDate.fromLocal(utc),
        CalendarDate.fromLocal(utc.toLocal()),
      );
    });
  });
}
