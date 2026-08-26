import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../theme/sai_tokens.dart';
import '../widgets/sai_dialog.dart';
import 'organise_commands.dart';
import '../widgets/glyph_button.dart';

/// A heading's "…" button in the project view, for tests.
Key headingMenuKey(HeadingId heading) => ValueKey('heading-menu-$heading');

/// The menu on a heading's section header (#74): rename, move up or down
/// among the project's headings, delete — its tasks stay in the project,
/// unheaded, unless the person says otherwise.
class HeadingMenu extends ConsumerWidget {
  const HeadingMenu({super.key, required this.heading, required this.title});

  final HeadingId heading;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final organise = ref.read(organiseCommandsProvider);
    Future<void> rename() async {
      final next = await promptForTitle(
        context,
        eyebrow: 'Heading',
        title: 'Rename “$title”',
        initial: title,
        confirm: 'Rename',
      );
      if (next != null && next != title) {
        await organise.renameHeading(heading, next);
      }
    }

    Future<void> delete() async {
      final count =
          ref
              .read(tasksProvider)
              .value
              ?.underHeading(heading, archived: true)
              .length ??
          0;
      final answer = await confirmAction(
        context,
        eyebrow: 'Heading',
        title: 'Delete “$title”?',
        body: count == 0
            ? 'It holds no open task. The archive keeps its history.'
            : 'The archive keeps its history.',
        confirm: 'Delete',
        option: count == 0
            ? null
            : 'Keep its $count open task${count == 1 ? '' : 's'} in the project, unheaded',
      );
      if (!answer.confirmed) return;
      await organise.deleteHeading(heading, moveTasks: answer.option);
    }

    return MenuAnchor(
      menuChildren: [
        MenuItemButton(onPressed: rename, child: const Text('Rename…')),
        MenuItemButton(
          onPressed: () => organise.nudgeHeading(heading, -1),
          child: const Text('Move up'),
        ),
        MenuItemButton(
          onPressed: () => organise.nudgeHeading(heading, 1),
          child: const Text('Move down'),
        ),
        MenuItemButton(onPressed: delete, child: const Text('Delete…')),
      ],
      builder: (context, controller, _) => GlyphButton(
        key: headingMenuKey(heading),
        glyph: '…',
        label: 'Options for $title',
        color: SaiColors.inkFaint,
        minSize: 20,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}
