import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../commands.dart';
import '../things/import_flow.dart';
import '../platform/finder.dart';
import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import 'settings_row.dart';

/// The Archive card's buttons and status line, for tests.
const revealInFinderKey = Key('reveal-in-finder');
const verifyHashesKey = Key('verify-hashes');
const verifyStatusKey = Key('verify-status');
const importThingsKey = Key('import-things');

/// Settings › Archive (#40): where the record lives and how big it is,
/// the Finder, the integrity pass — and nothing of what it holds.
class ArchivePage extends StatelessWidget {
  const ArchivePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsPageHeader(eyebrow: 'Archive', title: 'The record on disk'),
        ArchiveCard(),
        SizedBox(height: 18),
        _ImportRow(),
      ],
    );
  }
}

/// The reference's ARCHIVE card: eyebrow, the path in mono, the line and
/// byte counts, Reveal in Finder and Verify hashes.
class ArchiveCard extends ConsumerWidget {
  const ArchiveCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = context.saiText;
    final root = ref.watch(archiveRootProvider);
    final stats = ref.watch(archiveStatsProvider).value;
    final verify = ref.watch(archiveVerifyProvider);
    final commands = AppCommands.of(context);
    final line = stats == null
        ? 'counting…'
        : '${thousands(stats.count)} lines · ${megabytes(stats.bytes)} · '
              'every line hashes its own bytes';
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: SaiColors.ink),
        borderRadius: BorderRadius.circular(SaiRadius.large),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ARCHIVE',
            style: sans(
              10,
              weight: FontWeight.w600,
              letterSpacing: 1.6,
              color: SaiColors.inkFaint,
            ),
          ),
          const SizedBox(height: 9),
          SelectableText(
            homeRelative(root.path, ref.watch(environmentProvider)),
            style: mono(12, height: 1.5, color: SaiColors.ink),
          ),
          const SizedBox(height: 9),
          Text(
            line.toUpperCase(),
            style: mono(11, height: 1.5, color: SaiColors.inkFaint),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton(
                key: revealInFinderKey,
                onPressed: () => commands.revealArchive(),
                child: const Text('Reveal in Finder'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                key: verifyHashesKey,
                onPressed: verify is VerifyRunning
                    ? null
                    : () => ref.read(archiveVerifyProvider.notifier).verify(),
                child: const Text('Verify hashes'),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    key: verifyStatusKey,
                    switch (verify) {
                      VerifyIdle() => '',
                      VerifyRunning() => 'verifying…',
                      Verified(:final count) =>
                        'verified: ${thousands(count)} lines, every hash '
                            'matches',
                      VerifyFailed(:final message) => 'failed: $message',
                    },
                    style: text.meta,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The import, reachable after setup too: the same flow as first run.
class _ImportRow extends StatelessWidget {
  const _ImportRow();

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      label: 'Import from Things 3',
      helper: 'A preview first; run it again and only the differences land',
      control: OutlinedButton(
        key: importThingsKey,
        onPressed: () => showImportFlow(context),
        child: const Text('Import…'),
      ),
    );
  }
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

/// Bytes as the card shows them: `4.1 MB`, or `312 KB` under a megabyte.
String megabytes(int bytes) {
  if (bytes < 1 << 20) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
}

/// [path] with the home directory as `~`, the way the reference shows it.
String homeRelative(String path, Map<String, String> environment) {
  final home = environment['HOME'];
  if (home == null || home.isEmpty || !path.startsWith('$home/')) return path;
  return '~${path.substring(home.length)}';
}

/// Reveals the archive in the Finder; says so in the bar when no Finder
/// can be reached from here.
Future<void> revealArchiveInFinder(ProviderContainer container) async {
  final shown = await container
      .read(finderProvider)
      .reveal(container.read(archiveRootProvider).path);
  if (!shown) {
    container
        .read(noticeProvider.notifier)
        .show('the Finder is not available here');
  }
}
