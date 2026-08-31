import 'package:flutter/material.dart';

import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import 'settings_row.dart';

/// Every chord the app binds, in the order Help lists them — the one
/// table the Shortcuts page and the tests read.
const shortcutRows = <(String, String)>[
  ('⌘N', 'New task — the Inbox, with quick capture focused'),
  ('⌘K', 'Quick Find — or just start typing'),
  ('⌘1–⌘6', 'Inbox, Today, Upcoming, Anytime, Someday, Logbook'),
  ('⌘7', 'Trash'),
  ('↑ ↓', 'Move through the sidebar, or the list once a task is selected'),
  ('→', 'Into the list — or unfold a folded area'),
  ('←', 'Back to the sidebar — or fold the area'),
  ('⌘I', 'Open the inspector on the first row, or close it'),
  ('⇧⌘M', 'Move / Schedule… the selected task'),
  ('⌘↑ ⌘↓', 'Move the selected task up or down in its list'),
  ('⌘⏎', 'Complete the selected task (or reopen it)'),
  ('⌥⌘⏎', 'Cancel the selected task'),
  ('⌘⌫', 'Delete the selected task'),
  ('⌘J', 'Open the assistant, or tuck it away'),
  ('⇧⌘P', 'Ask the assistant to propose changes'),
  ('⌘Z', 'Undo the last change'),
  ('⌘R', 'Let the model think before it answers, or not'),
  ('⌘,', 'Settings'),
  ('⏎', 'Send the message to the assistant'),
  ('⇧⏎', 'New line in the message (⌥⏎ works too)'),
  ('Esc', "Stop the assistant's answer, or leave a field"),
];

/// Settings › Shortcuts (#40): the chords, chord in mono on the left.
class ShortcutsPage extends StatelessWidget {
  const ShortcutsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsPageHeader(
          eyebrow: 'Shortcuts',
          title: 'What the keys do',
        ),
        for (final (chord, what) in shortcutRows)
          Semantics(
            label: '$chord, $what',
            child: ExcludeSemantics(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: SaiColors.rule)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(chord, style: mono(12, color: SaiColors.ink)),
                    ),
                    Expanded(child: Text(what, style: text.body)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
