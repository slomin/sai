import 'dart:convert';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  const today = CalendarDate(2026, 9, 5);
  final profileId = BlobRef.sha256OfBytes(utf8.encode('profile'));

  Map<String, Object?> input({
    Object? title = 'Which shade of blue',
    Object? decided = '2026-08-23',
    Object? by = 'the guardian',
    Object? decision = 'The lighter one.',
    Object? alternatives = const ['the darker one', 'no blue at all'],
    Object? reasoning = 'It reads better in daylight.',
    Object? profile,
  }) => {
    'title': title,
    'decided': ?decided,
    'by': by,
    'decision': decision,
    'alternatives': ?alternatives,
    'reasoning': reasoning,
    'profile': ?profile,
  };

  Matcher refuses(String message) => throwsA(
    isA<FormatException>().having((e) => e.message, 'message', message),
  );

  group('fromInput', () {
    test('reads every field, trimmed', () {
      final d = Decision.fromInput(
        input(
          title: '  Which shade of blue ',
          by: ' the guardian\n',
          decision: '\nThe lighter one.\n\nIt was tried first.\n',
          alternatives: [' the darker one ', 'no blue at all'],
          profile: {'id': profileId.toString()},
        ),
        today: today,
      );
      expect(d.title, 'Which shade of blue');
      expect(d.decided, const CalendarDate(2026, 8, 23));
      expect(d.by, 'the guardian');
      expect(d.decision, 'The lighter one.\n\nIt was tried first.');
      expect(d.alternatives, ['the darker one', 'no blue at all']);
      expect(d.reasoning, 'It reads better in daylight.');
      expect(d.profile, profileId);
    });

    test('decided defaults to today and may not be in the future', () {
      expect(
        Decision.fromInput(input(decided: null), today: today).decided,
        today,
      );
      expect(
        Decision.fromInput(input(decided: '  '), today: today).decided,
        today,
      );
      // An explicit null — a template with every key spelled out — is
      // today too, as alternatives and profile already read null as none.
      expect(
        Decision.fromInput(input()..['decided'] = null, today: today).decided,
        today,
      );
      expect(
        Decision.fromInput(input(decided: '2026-09-05'), today: today).decided,
        today,
      );
      expect(
        () => Decision.fromInput(input(decided: '2026-09-06'), today: today),
        refuses('decision.decided is after today (2026-09-05)'),
      );
      expect(
        () => Decision.fromInput(input(decided: 20260905), today: today),
        refuses(
          'decision.decided must be a calendar date (YYYY-MM-DD), or empty '
          'for today',
        ),
      );
    });

    test('decided must be a real calendar date', () {
      for (final bad in ['2026-13-01', '2026-02-30', 'yesterday', '2026-9-5']) {
        expect(
          () => Decision.fromInput(input(decided: bad), today: today),
          refuses(
            'decision.decided is not a calendar date (YYYY-MM-DD): "$bad"',
          ),
        );
      }
    });

    test('the prose fields are required', () {
      for (final key in ['title', 'by', 'decision', 'reasoning']) {
        for (final bad in [null, '', '   ', 3]) {
          final map = input()..[key] = bad;
          expect(
            () => Decision.fromInput(map, today: today),
            refuses('decision.$key must be a non-empty string'),
            reason: '$key = $bad',
          );
        }
      }
    });

    test('the title and who decided are one line each', () {
      expect(
        () => Decision.fromInput(input(title: 'Two\nlines'), today: today),
        refuses('decision.title must be one line'),
      );
      expect(
        () => Decision.fromInput(input(by: 'one\nand another'), today: today),
        refuses('decision.by must be one line'),
      );
    });

    test('alternatives may be absent or empty, never malformed', () {
      expect(
        Decision.fromInput(
          input(alternatives: null),
          today: today,
        ).alternatives,
        isEmpty,
      );
      expect(
        Decision.fromInput(input(alternatives: []), today: today).alternatives,
        isEmpty,
      );
      for (final bad in [
        'the darker one',
        ['the darker one', ''],
        ['the darker one', 2],
        ['two\nlines'],
        {},
      ]) {
        expect(
          () => Decision.fromInput(input(alternatives: bad), today: today),
          refuses(
            'decision.alternatives must be a list of non-empty strings, one '
            'line each',
          ),
          reason: 'alternatives = $bad',
        );
      }
    });

    test('profile is an object naming a sha256 blobref', () {
      const message = 'decision.profile must be {"id": <sha256 blobref>}';
      for (final bad in [
        'sha256-abc',
        {'id': 'nonsense'},
        {'id': 'md5-00'},
        {'id': 'sha256-0'},
        {'ref': profileId.toString()},
      ]) {
        expect(
          () => Decision.fromInput(input(profile: bad), today: today),
          refuses(message),
          reason: 'profile = $bad',
        );
      }
    });

    test('an unknown key is a typo, not ignored', () {
      final map = input()..['reasons'] = 'x';
      expect(
        () => Decision.fromInput(map, today: today),
        refuses('unknown key in decision: "reasons"'),
      );
    });

    test('a decision is prose, not a document', () {
      final long = 'x' * (maxDecisionBytes + 1);
      expect(
        () => Decision.fromInput(input(reasoning: long), today: today),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            startsWith('the decision is too long: '),
          ),
        ),
      );
      // Just under fits.
      final fits = 'x' * (maxDecisionBytes - 400);
      expect(
        Decision.fromInput(input(reasoning: fits), today: today).reasoning,
        fits,
      );
    });
  });

  group('toPayload and fromPayload', () {
    test('round-trip, profile only when set', () {
      final plain = Decision.fromInput(input(), today: today);
      expect(plain.toPayload().containsKey('profile'), isFalse);
      expect(Decision.fromPayload(plain.toPayload()), plain);
      final withProfile = Decision.fromInput(
        input(profile: {'id': profileId.toString()}),
        today: today,
      );
      expect(withProfile.toPayload()['profile'], {'id': profileId.toString()});
      expect(Decision.fromPayload(withProfile.toPayload()), withProfile);
    });

    test('a later writer\'s key is ignored on read', () {
      final payload = Decision.fromInput(input(), today: today).toPayload()
        ..['supersedes'] = 'sha256-00';
      expect(Decision.fromPayload(payload).title, 'Which shade of blue');
    });

    test('a line missing a field this reader needs is refused', () {
      final payload = Decision.fromInput(input(), today: today).toPayload()
        ..remove('by');
      expect(
        () => Decision.fromPayload(payload),
        refuses('decision.by must be a non-empty string'),
      );
      expect(
        () => Decision.fromPayload({'title': 'x'}),
        refuses('decision.decided must be a non-empty string'),
      );
    });

    test('a line whose one-line fields hold a newline is refused', () {
      final payload = Decision.fromInput(input(), today: today).toPayload()
        ..['by'] = 'one\ntwo';
      expect(
        () => Decision.fromPayload(payload),
        refuses('decision.by must be one line'),
      );
    });

    test('no future check on read: an old line reads on any day', () {
      final payload = Decision.fromInput(input(), today: today).toPayload()
        ..['decided'] = '2099-01-01';
      expect(
        Decision.fromPayload(payload).decided,
        const CalendarDate(2099, 1, 1),
      );
    });
  });

  test('equality is by value', () {
    final a = Decision.fromInput(input(), today: today);
    final b = Decision.fromInput(input(), today: today);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(
      a,
      isNot(
        Decision.fromInput(
          input(alternatives: ['the darker one']),
          today: today,
        ),
      ),
    );
    expect(a.toString(), 'Decision(2026-08-23, Which shade of blue)');
  });
}
