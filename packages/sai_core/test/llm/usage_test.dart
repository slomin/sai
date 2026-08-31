import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  var nowMicros = DateTime.utc(2026, 8, 25, 10).microsecondsSinceEpoch;
  BlobRef? prev;

  setUp(() {
    nowMicros = DateTime.utc(2026, 8, 25, 10).microsecondsSinceEpoch;
    prev = null;
  });

  DateTime clock() {
    nowMicros += 1000000;
    return DateTime.fromMicrosecondsSinceEpoch(nowMicros, isUtc: true);
  }

  StoredEvent emit(
    String type, {
    Map<String, Object?> payload = const {},
    ModelRef? model,
    DateTime? ts,
    Actor actor = Actor.system,
  }) {
    final sealed = Event.seal(
      EventDraft(
        type: type,
        actor: actor,
        source: 'sai/test',
        payload: payload,
        model: model,
      ),
      prev: prev,
      ts: ts ?? clock(),
    );
    final id = sealed.deriveId();
    prev = id;
    return StoredEvent(id: id, event: sealed);
  }

  StoredEvent usage({
    String finish = 'stop',
    int? durationMs = 1500,
    int? promptTokens,
    int? completionTokens,
    int? totalTokens,
    double? cost,
    String? provider = 'fake',
    DateTime? ts,
  }) => emit(
    EventTypes.providerUsage,
    payload: {
      'finish': finish,
      if (durationMs != null) 'duration_ms': durationMs,
      if (promptTokens != null) 'prompt_tokens': promptTokens,
      if (completionTokens != null) 'completion_tokens': completionTokens,
      if (totalTokens != null) 'total_tokens': totalTokens,
      if (cost != null) 'cost': cost,
    },
    model: provider == null ? null : ModelRef(provider: provider, id: 'm'),
    ts: ts,
  );

  group('UsageProjection', () {
    test('empty holds nothing', () {
      final p = UsageProjection.replay(const []);
      expect(p.isEmpty, isTrue);
      expect(p.days, isEmpty);
    });

    test('totals one provider on one day', () {
      final p = UsageProjection.replay([
        usage(promptTokens: 100, completionTokens: 20, totalTokens: 120),
        usage(
          promptTokens: 200,
          completionTokens: 30,
          totalTokens: 230,
          durationMs: 500,
        ),
      ]);
      final day = CalendarDate.fromLocal(DateTime.utc(2026, 8, 25, 10));
      expect(p.days, [day]);
      final row = p.onDay(day).single;
      expect(row.provider, 'fake');
      expect(row.calls, 2);
      expect(row.failed, 0);
      expect(row.promptTokens, 300);
      expect(row.completionTokens, 50);
      expect(row.totalTokens, 350);
      expect(row.duration, const Duration(milliseconds: 2000));
      expect(row.cost, isNull);
    });

    test('ignores every other event type', () {
      final p = UsageProjection.replay([
        emit(EventTypes.chatMessage, payload: {'text': 'hi'}, actor: Actor.user),
        emit(
          EventTypes.providerRequest,
          payload: {'hash': 'x', 'payload': <String, Object?>{}},
        ),
        usage(),
        emit(EventTypes.providerFailure, payload: {'kind': 'network'}),
      ]);
      expect(p.days, hasLength(1));
      expect(p.onDay(p.days.single).single.calls, 1);
    });

    test('a failed call counts as a call and as failed', () {
      final p = UsageProjection.replay([
        usage(),
        usage(finish: 'failed'),
        usage(finish: 'cancelled'),
      ]);
      final row = p.onDay(p.days.single).single;
      expect(row.calls, 3);
      expect(row.failed, 1);
    });

    test('token sums stay unknown until a line reports them', () {
      final p = UsageProjection.replay([usage(), usage()]);
      final row = p.onDay(p.days.single).single;
      expect(row.promptTokens, isNull);
      expect(row.completionTokens, isNull);
      expect(row.totalTokens, isNull);
      expect(row.tokens, isNull);

      final q = UsageProjection.replay([usage(), usage(promptTokens: 5)]);
      expect(q.onDay(q.days.single).single.promptTokens, 5);
    });

    test('tokens falls back to prompt+completion without a total', () {
      final p = UsageProjection.replay([
        usage(promptTokens: 10, completionTokens: 4),
      ]);
      final row = p.onDay(p.days.single).single;
      expect(row.totalTokens, isNull);
      expect(row.tokens, 14);

      final q = UsageProjection.replay([
        usage(promptTokens: 10, completionTokens: 4, totalTokens: 15),
      ]);
      expect(q.onDay(q.days.single).single.tokens, 15);
    });

    test('cost stays null until a line carries it, then sums', () {
      final p = UsageProjection.replay([
        usage(),
        usage(cost: 0.0042),
        usage(cost: 0.0008),
      ]);
      final row = p.onDay(p.days.single).single;
      expect(row.cost, closeTo(0.005, 1e-9));
    });

    test('groups by provider and sorts providers by name', () {
      final p = UsageProjection.replay([
        usage(provider: 'lan'),
        usage(provider: 'fake'),
        usage(provider: 'lan'),
      ]);
      final rows = p.onDay(p.days.single);
      expect(rows.map((r) => r.provider), ['fake', 'lan']);
      expect(rows.map((r) => r.calls), [1, 2]);
    });

    test('buckets by local day of the event timestamp, newest first', () {
      // Two UTC instants that may or may not share a local day; the
      // expectation is derived through the same conversion the projection
      // uses, so the test holds in any zone.
      final early = DateTime.utc(2026, 8, 24, 23, 30);
      final late_ = DateTime.utc(2026, 8, 25, 0, 30);
      final p = UsageProjection.replay([
        usage(ts: early),
        usage(ts: late_),
      ]);
      final dayA = CalendarDate.fromLocal(early);
      final dayB = CalendarDate.fromLocal(late_);
      if (dayA == dayB) {
        expect(p.days, [dayA]);
        expect(p.onDay(dayA).single.calls, 2);
      } else {
        expect(p.days, [dayB, dayA]);
        expect(p.onDay(dayA).single.calls, 1);
        expect(p.onDay(dayB).single.calls, 1);
      }
    });

    test('a usage line without a model lands in the unknown bucket', () {
      final p = UsageProjection.replay([usage(provider: null)]);
      expect(p.onDay(p.days.single).single.provider, 'unknown');
    });

    test('tolerates a sparse or oddly typed payload', () {
      final p = UsageProjection.replay([
        emit(
          EventTypes.providerUsage,
          payload: {'finish': 'stop', 'prompt_tokens': 'many'},
          model: const ModelRef(provider: 'fake', id: 'm'),
        ),
      ]);
      final row = p.onDay(p.days.single).single;
      expect(row.calls, 1);
      expect(row.promptTokens, isNull);
      expect(row.duration, Duration.zero);
    });

    test('is deterministic', () {
      List<StoredEvent> events() {
        nowMicros = DateTime.utc(2026, 8, 25, 10).microsecondsSinceEpoch;
        prev = null;
        return [usage(promptTokens: 1), usage(provider: 'lan', cost: 0.1)];
      }

      final a = UsageProjection.replay(events());
      final b = UsageProjection.replay(events());
      expect(a.days, b.days);
      expect(a.onDay(a.days.first), b.onDay(b.days.first));
    });
  });

  group('the words', () {
    test('usageWords says only what is known', () {
      DailyUsage row({
        int calls = 1,
        int failed = 0,
        int? totalTokens,
        Duration duration = const Duration(seconds: 12),
        double? cost,
      }) => DailyUsage(
        day: const CalendarDate(2026, 8, 25),
        provider: 'fake',
        calls: calls,
        failed: failed,
        promptTokens: null,
        completionTokens: null,
        totalTokens: totalTokens,
        duration: duration,
        cost: cost,
      );
      expect(usageWords(row(duration: Duration.zero)), '1 call · 0s');
      expect(
        usageWords(
          row(
            calls: 3,
            failed: 1,
            totalTokens: 1234,
            duration: const Duration(seconds: 42),
          ),
        ),
        '3 calls (1 failed) · 1,234 tokens · 42s',
      );
      expect(
        usageWords(row(totalTokens: 135, cost: 0.0042)),
        '1 call · 135 tokens · 12s · \$0.0042',
      );
      expect(
        usageWords(row(totalTokens: 135, cost: 1.234)),
        '1 call · 135 tokens · 12s · \$1.23',
      );
    });

    test('thousands', () {
      expect(thousands(0), '0');
      expect(thousands(999), '999');
      expect(thousands(18402), '18,402');
      expect(thousands(1234567), '1,234,567');
    });

    test('elapsedWords', () {
      expect(elapsedWords(Duration.zero), '0s');
      expect(elapsedWords(const Duration(milliseconds: 400)), '<1s');
      expect(elapsedWords(const Duration(seconds: 12)), '12s');
      expect(elapsedWords(const Duration(seconds: 102)), '1m 42s');
      expect(elapsedWords(const Duration(minutes: 62, seconds: 5)), '1h 2m');
    });
  });
}
