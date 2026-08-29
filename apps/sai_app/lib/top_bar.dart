import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'commands.dart';
import 'theme/sai_theme.dart';
import 'theme/sai_tokens.dart';
import 'widgets/notice_line.dart';

/// The Undo button and the assistant toggle, for tests.
const undoButtonKey = Key('undo');
const assistantButtonKey = Key('assistant-toggle');

/// The `DEV` label the dev flavor wears at all times (ADR 0019).
const devLabelKey = Key('dev-label');

/// The mark: a red square held inside an ink square.
class SaiMark extends StatelessWidget {
  const SaiMark({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        color: SaiColors.ink,
        alignment: Alignment.center,
        child: Container(
          width: size / 3,
          height: size / 3,
          color: SaiColors.red,
        ),
      ),
    );
  }
}

/// The bar across the top: the mark and the archive line on the left,
/// the last notice, then Undo and the assistant toggle on the right.
class TopBar extends ConsumerWidget {
  const TopBar({super.key, required this.projection});

  final TaskProjection projection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = context.saiText;
    final commands = AppCommands.of(context);
    final canUndo = ref.watch(canUndoProvider);
    final shown = ref.watch(chatVisibleProvider);
    // Every writer appends to the archive, not only the task store, so
    // the count comes from the log's head (archiveLineCountProvider); the
    // projection's own count stands in until the first read lands.
    final lines =
        ref.watch(archiveLineCountProvider).value ?? projection.eventCount;
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: SaiColors.bg,
        border: Border(bottom: BorderSide(color: SaiColors.rule)),
      ),
      child: Row(
        children: [
          const SaiMark(),
          const SizedBox(width: 12),
          Text('sai', style: text.brand),
          if (ref.watch(identityProvider).isDev) ...[
            const SizedBox(width: 8),
            Container(
              key: devLabelKey,
              padding: const EdgeInsets.fromLTRB(6, 3, 6, 2),
              decoration: BoxDecoration(
                color: SaiColors.redTint,
                borderRadius: const BorderRadius.all(
                  Radius.circular(SaiRadius.small),
                ),
              ),
              child: Text('DEV', style: text.eyebrow),
            ),
          ],
          const SizedBox(width: 16),
          Text(
            'ARCHIVE · $lines ${lines == 1 ? 'LINE' : 'LINES'}',
            style: text.meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(width: 16),
          Expanded(child: NoticeLine(ref.watch(noticeProvider))),
          const SizedBox(width: 16),
          TextButton(
            key: undoButtonKey,
            onPressed: canUndo ? commands.undo : null,
            child: const Text('Undo'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: assistantButtonKey,
            onPressed: commands.toggleChat,
            style: OutlinedButton.styleFrom(
              foregroundColor: SaiColors.ink,
              side: const BorderSide(color: SaiColors.ink, width: 1.5),
              textStyle: text.button,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(
                  Radius.circular(SaiRadius.medium),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            icon: Container(width: 8, height: 8, color: SaiColors.red),
            label: Text(shown ? 'Assistant ⌘J' : 'Assistant ⌘J'),
          ),
        ],
      ),
    );
  }
}
