/// The propose/confirm lane (#35): the latest proposal's cards beside
/// the transcript, on the band's ink surface — a proposal never looks
/// like a task you already own. Nothing changes until Accept, which
/// applies through the store as the assistant and is one ⌘Z away from
/// undone; a stale card (its task changed since the proposal) can only
/// be rejected.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../commands.dart';
import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import 'chat_keys.dart';

class SuggestionLane extends ConsumerWidget {
  const SuggestionLane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final views = ref.watch(suggestionViewsProvider);
    final note = ref.watch(
      proposalsProvider.select((s) => s.current?.note ?? ''),
    );
    final commands = AppCommands.of(context);
    final text = context.saiText;
    return ListView(
      key: suggestionLaneKey,
      padding: const EdgeInsets.only(top: 8, right: 24, bottom: 8),
      children: [
        Text('SUGGESTIONS', style: text.eyebrow),
        if (note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              note,
              style: text.small.copyWith(color: SaiColors.sheetDim),
            ),
          ),
        for (final view in views) _SuggestionCard(view, commands),
      ],
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard(this.view, this.commands);

  final SuggestionView view;
  final AppCommands commands;

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    final item = view.item;
    final dim = item.status == SuggestionStatus.rejected;
    return Container(
      key: suggestionCardKey(item.index),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: SaiColors.sheetCard,
        border: Border.all(color: SaiColors.sheetRule),
        borderRadius: BorderRadius.circular(SaiRadius.medium),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.headline,
                  style: text.body.copyWith(
                    color: dim ? SaiColors.sheetDim : SaiColors.sheetText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (view.stale)
                Text(
                  'STALE',
                  style: text.chip.copyWith(color: SaiColors.amber),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            item.targetTitle,
            style: text.small.copyWith(color: SaiColors.sheetDim),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (item.kind == SuggestionKind.split)
            Text(
              item.parts.join(' · '),
              style: text.small.copyWith(color: SaiColors.sheetDim),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: 4),
          Text(
            item.reason,
            style: text.small.copyWith(color: SaiColors.sheetDim),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          switch (item.status) {
            SuggestionStatus.pending => Row(
              children: [
                FilledButton(
                  key: suggestionAcceptKey(item.index),
                  onPressed: view.stale
                      ? null
                      : () => commands.acceptSuggestion(item.index),
                  style: FilledButton.styleFrom(
                    backgroundColor: SaiColors.red,
                    foregroundColor: SaiColors.white,
                    disabledBackgroundColor: SaiColors.sheetCard,
                    disabledForegroundColor: SaiColors.sheetDim,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Accept'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: suggestionRejectKey(item.index),
                  onPressed: () => commands.rejectSuggestion(item.index),
                  style: FilledButton.styleFrom(
                    backgroundColor: SaiColors.sheetCard,
                    foregroundColor: SaiColors.sheetText,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Reject'),
                ),
              ],
            ),
            SuggestionStatus.accepted => Text(
              'applied · ⌘Z undoes',
              style: text.chip.copyWith(color: SaiColors.green),
            ),
            SuggestionStatus.rejected => Text(
              'rejected',
              style: text.chip.copyWith(color: SaiColors.sheetDim),
            ),
            SuggestionStatus.failed => Text(
              'failed: ${item.failure}',
              style: text.small.copyWith(color: SaiColors.red),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          },
        ],
      ),
    );
  }
}
