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
const backupPathKey = Key('backup-path');
const backupSetKey = Key('backup-set');
const backupNowKey = Key('backup-now');
const backupStatusKey = Key('backup-status');

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
        BackupRow(),
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

/// Where the log is copied (#15, ADR 0025): the destination, a copy on
/// demand, and what the last copy did — the count, never a line.
class BackupRow extends ConsumerStatefulWidget {
  const BackupRow({super.key});

  @override
  ConsumerState<BackupRow> createState() => _BackupRowState();
}

class _BackupRowState extends ConsumerState<BackupRow> {
  late final TextEditingController _path;

  /// Why the last Set was refused, until the next one.
  String? _problem;

  @override
  void initState() {
    super.initState();
    _path = TextEditingController(
      text: ref.read(settingsProvider).archiveBackup ?? '',
    );
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  void _set() {
    final typed = _path.text.trim();
    final settings = ref.read(settingsProvider.notifier);
    if (typed.isEmpty) {
      setState(() => _problem = null);
      settings.setArchiveBackup(null);
      return;
    }
    final reason = Settings.checkArchiveBackup(
      typed,
      archiveRoot: ref.read(archiveRootProvider).path,
    );
    setState(() => _problem = reason);
    if (reason != null) return;
    settings.setArchiveBackup(typed);
    ref.read(archiveBackupProvider.notifier).backupNow();
  }

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    final destination = ref.watch(
      settingsProvider.select((s) => s.archiveBackup),
    );
    final backup = ref.watch(archiveBackupProvider);
    final status =
        _problem ?? backupStatus(backup, configured: destination != null);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 15),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: SaiColors.rule)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Back up to',
            style: text.body.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 3),
          Text(
            'A second copy of the record, on another disk or a mount. It '
            'is kept in step while sai runs; every line is hashed on copy.',
            style: text.small.copyWith(color: SaiColors.inkFaint),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: backupPathKey,
                  controller: _path,
                  style: mono(12, height: 1.5, color: SaiColors.ink),
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    hintText: '/Volumes/Backup/sai',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _set(),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                key: backupSetKey,
                onPressed: _set,
                child: const Text('Set'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: backupNowKey,
                onPressed: destination == null || backup is BackupRunning
                    ? null
                    : () =>
                          ref.read(archiveBackupProvider.notifier).backupNow(),
                child: const Text('Back up now'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              key: backupStatusKey,
              status,
              style: _problem == null
                  ? text.meta
                  : text.note.copyWith(color: SaiColors.redInk),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// The status line under the destination: what the replica holds, or
/// why it does not. A time is the local clock's, so a person can tell a
/// copy from this morning from one from last week.
String backupStatus(BackupState state, {required bool configured}) =>
    switch (state) {
      BackupIdle() =>
        configured
            ? 'waiting for the first copy'
            : 'not backed up — set a destination',
      BackupRunning() => 'copying…',
      BackedUp(:final count, :final at) =>
        'backed up: ${thousands(count)} lines, every hash matches · '
            '${_clockTime(at.toLocal())}',
      BackupSkipped(:final reason) => 'skipped: $reason',
      BackupFailed(:final message) => 'failed: $message',
    };

String _clockTime(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';

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
