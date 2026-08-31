/// The read side of provider traffic (#30): daily totals folded from the
/// `provider.usage` lines the recorder writes (ADR 0007). The projection
/// never writes and never throws on a strange payload — the archive's
/// validation lives elsewhere; here an unreadable field is an unknown one.
library;

import '../archive/archive.dart';
import '../archive/event.dart';
import '../tasks/date.dart';
import 'call.dart';

/// One provider's totals for one local calendar day.
final class DailyUsage {
  const DailyUsage({
    required this.day,
    required this.provider,
    required this.calls,
    required this.failed,
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.tokens,
    required this.duration,
    required this.cost,
  });

  final CalendarDate day;

  /// The `model.provider` of the answering backend, or `unknown` when a
  /// usage line carried no model block.
  final String provider;

  final int calls;

  /// Calls whose `finish` was `failed`. Cancellations are not failures.
  final int failed;

  /// Token sums stay null until a line reports the field — an unknown is
  /// not a zero.
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;

  final Duration duration;

  /// Provider-reported cost, summed; null until any line carries it.
  /// Locals never report cost, and nothing here estimates one.
  final double? cost;

  /// The best token count, summed per call — each line contributes its
  /// reported total, else prompt+completion — so a day mixing payload
  /// shapes never drops the component-only lines. Null until any line
  /// reported tokens at all.
  final int? tokens;

  @override
  bool operator ==(Object other) =>
      other is DailyUsage &&
      other.day == day &&
      other.provider == provider &&
      other.calls == calls &&
      other.failed == failed &&
      other.promptTokens == promptTokens &&
      other.completionTokens == completionTokens &&
      other.totalTokens == totalTokens &&
      other.tokens == tokens &&
      other.duration == duration &&
      other.cost == cost;

  @override
  int get hashCode => Object.hash(
    day,
    provider,
    calls,
    failed,
    promptTokens,
    completionTokens,
    totalTokens,
    tokens,
    duration,
    cost,
  );

  @override
  String toString() =>
      'DailyUsage($day $provider: $calls calls, $failed failed, '
      '${tokens ?? '?'} tokens, $duration${cost == null ? '' : ', \$$cost'})';
}

/// Daily usage totals replayed from the archive, keyed by local day and
/// provider. Pure and immutable; a refresh is a new replay.
final class UsageProjection {
  UsageProjection._(this._rows);

  /// Folds [events], keeping only `provider.usage` lines.
  factory UsageProjection.replay(Iterable<StoredEvent> events) {
    final rows = <(CalendarDate, String), _Sum>{};
    for (final stored in events) {
      final event = stored.event;
      if (event.type != EventTypes.providerUsage) continue;
      final key = (
        CalendarDate.fromLocal(event.ts),
        event.model?.provider ?? 'unknown',
      );
      final sum = rows.putIfAbsent(key, _Sum.new);
      final payload = event.payload;
      sum.calls++;
      if (payload['finish'] == LlmFinish.failed.name) sum.failed++;
      if (payload['duration_ms'] case final int ms) {
        sum.durationMs += ms < 0 ? 0 : ms;
      }
      final prompt = payload['prompt_tokens'] is int
          ? payload['prompt_tokens'] as int
          : null;
      final completion = payload['completion_tokens'] is int
          ? payload['completion_tokens'] as int
          : null;
      final total = payload['total_tokens'] is int
          ? payload['total_tokens'] as int
          : null;
      if (prompt != null) sum.promptTokens = (sum.promptTokens ?? 0) + prompt;
      if (completion != null) {
        sum.completionTokens = (sum.completionTokens ?? 0) + completion;
      }
      if (total != null) sum.totalTokens = (sum.totalTokens ?? 0) + total;
      // This call's best count: the reported total, else the components
      // — decided per line, so mixed payload shapes still all count.
      final best =
          total ??
          ((prompt == null && completion == null)
              ? null
              : (prompt ?? 0) + (completion ?? 0));
      if (best != null) sum.tokens = (sum.tokens ?? 0) + best;
      if (payload['cost'] case final num c) {
        sum.cost = (sum.cost ?? 0) + c.toDouble();
      }
    }
    return UsageProjection._({
      for (final MapEntry(key: (day, provider), value: sum) in rows.entries)
        (day, provider): DailyUsage(
          day: day,
          provider: provider,
          calls: sum.calls,
          failed: sum.failed,
          promptTokens: sum.promptTokens,
          completionTokens: sum.completionTokens,
          totalTokens: sum.totalTokens,
          tokens: sum.tokens,
          duration: Duration(milliseconds: sum.durationMs),
          cost: sum.cost,
        ),
    });
  }

  final Map<(CalendarDate, String), DailyUsage> _rows;

  bool get isEmpty => _rows.isEmpty;

  /// Every day that saw a call, newest first.
  List<CalendarDate> get days {
    final seen = <CalendarDate>{for (final (day, _) in _rows.keys) day};
    return seen.toList()..sort((a, b) => b.compareTo(a));
  }

  /// The totals for [day], one row per provider, sorted by provider name.
  List<DailyUsage> onDay(CalendarDate day) {
    final rows = [
      for (final MapEntry(key: (rowDay, _), value: row) in _rows.entries)
        if (rowDay == day) row,
    ];
    return rows..sort((a, b) => a.provider.compareTo(b.provider));
  }
}

final class _Sum {
  int calls = 0;
  int failed = 0;
  int durationMs = 0;
  int? promptTokens;
  int? completionTokens;
  int? totalTokens;
  int? tokens;
  double? cost;
}

/// One row's numbers the way both clients say them:
/// `3 calls (1 failed) · 1,234 tokens · 42s · $0.0042`. Every piece
/// appears only when it is known; cost keeps four decimals under a
/// cent, two above.
String usageWords(DailyUsage row) {
  final calls = '${row.calls} ${row.calls == 1 ? 'call' : 'calls'}';
  final failed = row.failed == 0 ? '' : ' (${row.failed} failed)';
  final tokens = row.tokens == null
      ? ''
      : ' · ${thousands(row.tokens!)} tokens';
  final cost = switch (row.cost) {
    null => '',
    final c when c < 0.01 => ' · \$${c.toStringAsFixed(4)}',
    final c => ' · \$${c.toStringAsFixed(2)}',
  };
  return '$calls$failed$tokens · ${elapsedWords(row.duration)}$cost';
}

/// `18402` as `18,402`.
String thousands(int n) {
  final digits = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// A wall-clock span the way the totals read it: `1h 2m`, `1m 42s`,
/// `12s`, `<1s` for anything real but sub-second.
String elapsedWords(Duration d) {
  if (d == Duration.zero) return '0s';
  if (d < const Duration(seconds: 1)) return '<1s';
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}
