import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../widgets/sai_toggle.dart';
import 'archive_page.dart';
import 'settings_row.dart';

/// The assistant-on-launch switch, for tests.
const assistantOnLaunchKey = Key('assistant-on-launch');

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsPageHeader(eyebrow: 'General', title: 'How sai behaves'),
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
