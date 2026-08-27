import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import '../widgets/sai_toggle.dart';
import 'archive_page.dart';
import 'settings_row.dart';

/// The assistant-on-launch switch, for tests.
const assistantOnLaunchKey = Key('assistant-on-launch');
const settingsProblemKey = Key('settings-problem');

/// Settings › General (#40): how sai behaves. One row for now — the
/// assistant's band at launch — and the Archive card the reference puts
/// under it. Appearance and the week's first day wait for a consumer.
class GeneralPage extends ConsumerWidget {
  const GeneralPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The switch is the band's own state: the workspace remembers it at
    // launch (`workspace.assistant_visible`), so "starts expanded" is
    // exactly "is expanded now" — one owner, no second key to drift.
    final open = ref.watch(chatVisibleProvider);
    final problem = ref.watch(settingsProvider.select((s) => s.problem));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsPageHeader(eyebrow: 'General', title: 'How sai behaves'),
        // A quarantined or refused settings file, said where the settings
        // are (ADR 0006): what the status line only calls "unreadable".
        if (problem case final problem?)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Semantics(
              liveRegion: true,
              child: Text(
                problem,
                key: settingsProblemKey,
                style: context.saiText.note.copyWith(color: SaiColors.redInk),
              ),
            ),
          ),
        SettingsRow(
          label: 'Open the assistant with the app',
          helper: 'The ink band starts expanded',
          control: SaiToggle(
            key: assistantOnLaunchKey,
            value: open,
            label: 'Open the assistant with the app',
            onChanged: ref.read(chatVisibleProvider.notifier).set,
          ),
        ),
        const SizedBox(height: 18),
        const ArchiveCard(),
      ],
    );
  }
}
