import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  group('decodeThingsDay', () {
    test('unpacks year, month and day bit fields', () {
      // 2026 << 16 | 8 << 12 | 24 << 7
      expect(decodeThingsDay(132811776), const CalendarDate(2026, 8, 24));
      expect(decodeThingsDay(132497152), const CalendarDate(2021, 11, 30));
    });

    test('null and zero are no date', () {
      expect(decodeThingsDay(null), isNull);
      expect(decodeThingsDay(0), isNull);
    });

    test('round-trips through encodeThingsDay', () {
      for (final date in const [
        CalendarDate(2000, 1, 1),
        CalendarDate(2024, 2, 29),
        CalendarDate(2099, 12, 31),
      ]) {
        expect(decodeThingsDay(encodeThingsDay(date)), date);
      }
    });

    test('refuses a day that does not exist, naming the raw value', () {
      final packed =
          encodeThingsDay(const CalendarDate(2026, 2, 28)) + (2 << 7);
      expect(
        () => decodeThingsDay(packed),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'not a Things day: $packed',
          ),
        ),
      );
    });
  });

  group('decodeThingsInstant', () {
    test('reads Unix seconds as a UTC instant with microseconds', () {
      final instant = decodeThingsInstant(1638265903.79922);
      expect(instant, DateTime.utc(2021, 11, 30, 9, 51, 43, 799, 220));
      expect(instant!.isUtc, isTrue);
    });

    test('accepts an integer and keeps null', () {
      expect(decodeThingsInstant(0), DateTime.utc(1970));
      expect(decodeThingsInstant(null), isNull);
    });
  });
}
