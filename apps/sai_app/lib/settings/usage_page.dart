import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import '../workspace/dates.dart';
import 'settings_row.dart';

/// The card and its day rows, for tests.
const usageCardKey = Key('usage-card');
Key usageDayKey(CalendarDate day) => ValueKey(('usage-day', day));

/// Settings › Usage (#30): what the models did, by day and provider —
/// counts folded from the archive's own usage lines, never estimates.
class UsagePage extends ConsumerWidget {
  const UsagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(dailyUsageProvider).value;
    final today = ref.watch(todayProvider);
    final earlier = usage == null
        ? const <CalendarDate>[]
        : usage.days.where((d) => d < today).take(7).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsPageHeader(
          eyebrow: 'Usage',
          title: 'What the models did',
        ),
        _UsageCard(usage: usage, today: today),
        for (final day in earlier) _DayRows(day: day, rows: usage!.onDay(day)),
      ],
    );
  }
}

/// The TODAY card, in the Archive card's treatment: an eyebrow and one
/// mono line per provider.
class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.usage, required this.today});

  final UsageProjection? usage;
  final CalendarDate today;

  @override
  Widget build(BuildContext context) {
    final rows = usage?.onDay(today) ?? const <DailyUsage>[];
    return Container(
      key: usageCardKey,
      decoration: BoxDecoration(
        border: Border.all(color: SaiColors.ink),
        borderRadius: BorderRadius.circular(SaiRadius.large),
      ),
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'TODAY',
            style: sans(
              10,
              weight: FontWeight.w600,
              letterSpacing: 1.6,
              color: SaiColors.inkFaint,
            ),
          ),
          const SizedBox(height: 9),
          if (usage == null)
            Text(
              'COUNTING…',
              style: mono(11, height: 1.5, color: SaiColors.inkFaint),
            )
          else if (rows.isEmpty)
            Text(
              'NO CALLS TODAY',
              style: mono(11, height: 1.5, color: SaiColors.inkFaint),
            )
          else
            for (final row in rows) _ProviderLine(row),
        ],
      ),
    );
  }
}

/// One earlier day: the day word on the left, its provider lines beside.
class _DayRows extends StatelessWidget {
  const _DayRows({required this.day, required this.rows});

  final CalendarDate day;
  final List<DailyUsage> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: usageDayKey(day),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: SaiColors.rule)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              shortDay(day).toUpperCase(),
              style: mono(11, height: 1.5, color: SaiColors.inkFaint),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final row in rows) _ProviderLine(row)],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderLine extends StatelessWidget {
  const _ProviderLine(this.row);

  final DailyUsage row;

  @override
  Widget build(BuildContext context) {
    return Text(
      '${row.provider} · ${usageWords(row)}'.toUpperCase(),
      style: mono(11, height: 1.5, color: SaiColors.ink),
    );
  }
}
