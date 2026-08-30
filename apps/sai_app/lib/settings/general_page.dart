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

/// The finished-tasks switch (#97), for tests.
const finishedVisibleKey = Key('finished-visible');

/// The lifecycle notes (#97), for tests.
const lifecycleNotesKey = Key('lifecycle-notes');

/// What each lifecycle word means (#97), in the order a task meets them.
/// One place for the copy: the notes render it and the tests read it.
const lifecycleNotes = <(String, String)>[
  ('Complete', 'Done. The check on a row, or Task › Complete.'),
  (
    'Cancel',
    'Let go on purpose, not done. The cross at the end of a hovered or '
        'selected row, Task › Cancel, or Cancel in the inspector.',
  ),
  (
    'Logbook',
    'Where completed and cancelled tasks go the moment it happens, day by '
        'day. Check a row there to reopen it.',
  ),
  (
    'Delete',
    'Task › Delete moves a task to the Trash. Its history stays in the '
        'archive.',
  ),
  (
    'Trash',
    'Deleted tasks, exactly as they were. Restore brings one back; '
        'nothing else can be done to it there.',
  ),
  (
    'Archive',
    'An area or a project, from its sidebar menu: it leaves the sidebar '
        'with its tasks, and Unarchive brings everything back.',
  ),
];

/// Settings › General (#40): how sai behaves — the assistant's band at
/// launch, when a finished task leaves its list (#97) with the words
/// that flow uses, and the Archive card the reference puts under it.
/// Appearance and the week's first day wait for a consumer.
class GeneralPage extends ConsumerWidget {
  const GeneralPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The switch is the band's own state: the workspace remembers it at
    // launch (`workspace.assistant_visible`), so "starts expanded" is
    // exactly "is expanded now" — one owner, no second key to drift.
    final open = ref.watch(chatVisibleProvider);
    final finished = ref.watch(finishedTaskVisibilityProvider);
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
        SettingsRow(
          label: 'Keep finished tasks visible until the end of the day',
          helper:
              'Completed and cancelled tasks stay in their lists, greyed, '
              'until midnight. Off, they collapse into the Logbook at once.',
          control: SaiToggle(
            key: finishedVisibleKey,
            value: finished == FinishedTaskVisibility.endOfDay,
            label: 'Keep finished tasks visible until the end of the day',
            onChanged: (on) => ref
                .read(settingsProvider.notifier)
                .setFinishedTaskVisibility(
                  on
                      ? FinishedTaskVisibility.endOfDay
                      : FinishedTaskVisibility.immediate,
                ),
          ),
        ),
        const _LifecycleNotes(),
        const SizedBox(height: 18),
        const ArchiveCard(),
      ],
    );
  }
}

/// The words a task's life uses, each in one line (#97): what the row
/// controls, the menu and the sidebar do, said where the switch above
/// changes one of them.
class _LifecycleNotes extends StatelessWidget {
  const _LifecycleNotes();

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    return Container(
      key: lifecycleNotesKey,
      padding: const EdgeInsets.symmetric(vertical: 15),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: SaiColors.rule)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('What the words mean', style: text.eyebrow),
          const SizedBox(height: 8),
          for (final (term, meaning) in lifecycleNotes)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 84,
                    child: Text(
                      term,
                      style: text.body.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      meaning,
                      style: text.small.copyWith(color: SaiColors.inkFaint),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
