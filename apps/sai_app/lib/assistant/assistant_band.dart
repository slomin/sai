import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../commands.dart';
import '../theme/motion.dart';
import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import 'chat_composer.dart';
import 'chat_keys.dart';
import 'markdown/sai_markdown.dart';
import 'selection_join.dart';
import 'suggestion_lane.dart';
import 'waiting_dots.dart';

export 'chat_keys.dart';

/// The band's selection colours (#99): the transcript's highlight and
/// the composer's caret in the band's own light, since the app theme's
/// ink primary would vanish on the ink surface.
final bandSelectionTheme = TextSelectionThemeData(
  cursorColor: SaiColors.sheetText,
  selectionColor: SaiColors.sheetText.withValues(alpha: 0.28),
  selectionHandleColor: SaiColors.sheetText,
);

/// What the empty band says.
const chatEmptyHint =
    'Ask about your list — what is due, what is coming up, what you '
    'finished. A local model sees every task, Logbook and Trash included; '
    'a cloud one reads at most Today and Upcoming. The assistant can '
    'propose changes — nothing changes until you accept.';

/// How tall the open band's body is for a main column of [height]: about
/// two fifths, within bounds, so a short window keeps its list.
double assistantBandHeight(double height) => (height * 0.4).clamp(160.0, 360.0);

/// The ink band (#72): the assistant on a different surface from the
/// list, docked under it. The header names the provider and stays when
/// the band is tucked away (⌘J); the body is the conversation (#34) —
/// the transcript from [chatProvider], the answer as it streams, and the
/// composer (multi-line: Enter sends, ⇧⏎ breaks the line — #39). Opening and closing animate through [SaiMotion]; the draft
/// and focus live in `commands.dart`, so nothing is lost either way.
class AssistantBand extends ConsumerWidget {
  const AssistantBand({super.key, required this.bodyHeight});

  /// The open body's height ([assistantBandHeight] of the column).
  final double bodyHeight;

  /// The open body sits under the assistant's focus node (#76), so the
  /// Task chords know when the keyboard is the chat's.
  Widget body(bool open, FocusNode scope) => open
      ? SizedBox(
          height: bodyHeight,
          child: Focus(focusNode: scope, child: const _ChatBody()),
        )
      : const SizedBox(width: double.infinity);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(chatVisibleProvider);
    final scope = ref.watch(assistantFocusProvider);
    final commands = AppCommands.of(context);
    final status = ref.watch(llmStatusProvider);
    final connection = ref.watch(connectionProvider);
    // Watching also keeps the warmer alive for the app's life (#105).
    final warm = ref.watch(cacheWarmerProvider);
    final shown = warm.phase == WarmPhase.warming
        ? '$status · ${warmingWord(warm.fraction)}'
        : status;
    return Container(
      decoration: const BoxDecoration(
        color: SaiColors.sheetBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(
            status: shown,
            connection: connection,
            open: open,
            onTap: commands.toggleChat,
          ),
          // A zero-length AnimatedSize still animates — and marks itself
          // dirty during layout — so under Reduce Motion the body just is.
          if (SaiMotion.reduced(context))
            body(open, scope)
          else
            AnimatedSize(
              duration: SaiDurations.band,
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: body(open, scope),
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.status,
    required this.connection,
    required this.open,
    required this.onTap,
  });

  final String status;
  final ConnectionStatus connection;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mono = context.saiText.meta;
    return Semantics(
      button: true,
      // The light is spoken, never only coloured (#40).
      label:
          '${open ? 'Tuck the assistant away' : 'Open the assistant'}. '
          'Assistant ${connection.spoken}. $status',
      child: InkWell(
        key: assistantHeaderKey,
        onTap: onTap,
        child: SizedBox(
          height: 44,
          // The header's own label speaks for it.
          child: ExcludeSemantics(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  ConnectionDot(level: connection.level),
                  const SizedBox(width: 10),
                  Text(
                    'ASSISTANT',
                    style: mono.copyWith(
                      color: SaiColors.sheetText,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    connection.text.toUpperCase(),
                    key: connectionTextKey,
                    style: mono.copyWith(
                      color: connectionColor(connection.level),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      status,
                      style: mono.copyWith(color: SaiColors.sheetDim),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    open ? '⌘J TO TUCK AWAY' : '⌘J TO OPEN',
                    style: mono.copyWith(color: SaiColors.sheetDim),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatBody extends ConsumerStatefulWidget {
  const _ChatBody();

  @override
  ConsumerState<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends ConsumerState<_ChatBody> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  var _followPending = false;

  /// Keeps the newest text in view as it arrives — but only while the
  /// reader is at the bottom; someone who scrolled up to re-read stays
  /// there. One jump per frame, however many deltas landed in it.
  void _follow() {
    if (_followPending || !_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels < position.maxScrollExtent - 48) return;
    _followPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followPending = false;
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(chatProvider, (_, _) => _follow());
    final state = ref.watch(chatProvider);
    final reasoningOn = ref.watch(reasoningProvider);
    final lane = ref.watch(suggestionViewsProvider).isNotEmpty;
    // The band is ink on a light theme: the selection highlight and the
    // caret take the band's own light, for the transcript and the
    // composer alike.
    return TextSelectionTheme(
      data: bandSelectionTheme,
      child: Column(
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _transcript(state, reasoningOn)),
                // The lane (#35): the latest proposal's cards, beside
                // the talk, only while there is one.
                if (lane) const SizedBox(width: 300, child: SuggestionLane()),
              ],
            ),
          ),
          const ChatComposer(),
        ],
      ),
    );
  }

  Widget _transcript(ChatState state, bool reasoningOn) {
    final text = context.saiText;
    return state.turns.isEmpty && !state.busy
        ? Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: Text(
                chatEmptyHint,
                style: text.small.copyWith(color: SaiColors.sheetDim),
              ),
            ),
          )
        // The transcript is under the desktop selection system
        // (#99): a mouse drag selects across a person's plain text
        // and the rendered Markdown alike, ⌘C copies it; touch and
        // the wheel still scroll.
        : SelectionArea(
            child: ListView(
              key: chatTranscriptKey,
              controller: _scroll,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              children: [
                SelectionJoin(
                  separator: '\n\n',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // One boundary per turn, as the list gave
                      // each child: a delta repaints its row.
                      for (final turn in state.turns)
                        RepaintBoundary(
                          child: _TurnRow(turn, reasoningOn: reasoningOn),
                        ),
                      if (state.busy)
                        _Row(
                          who: 'sai',
                          reasoning: reasoningOn ? state.reasoning : null,
                          text: state.streaming!,
                          leading: state.streaming!.isEmpty
                              ? WaitingDots(
                                  key: chatWaitingKey,
                                  // Named after what is shown:
                                  // thinking the setting hides
                                  // stays unmentioned.
                                  label: state.phase == ChatPhase.proposing
                                      ? 'sai is proposing'
                                      : reasoningOn && state.reasoning != null
                                      ? 'sai is thinking'
                                      : 'Waiting for sai',
                                )
                              : null,
                          markdown: true,
                          caret: true,
                          note: state.tasksWithheld ? tasksWithheldWord : null,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
  }
}

class _TurnRow extends StatelessWidget {
  const _TurnRow(this.turn, {required this.reasoningOn});

  final ChatTurn turn;
  final bool reasoningOn;

  @override
  Widget build(BuildContext context) {
    final failure = turn.failure;
    final notes = turnNotes(turn);
    return _Row(
      who: turn.role == ChatRole.user ? 'you' : 'sai',
      reasoning: reasoningOn ? turn.reasoning : null,
      text: turn.text,
      markdown: turn.role == ChatRole.assistant,
      note: notes.isEmpty ? null : notes.join(' · '),
      error: failure == null ? null : chatFailureLine(failure),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.who,
    required this.text,
    this.markdown = false,
    this.caret = false,
    this.leading,
    this.reasoning,
    this.note,
    this.error,
  });

  final String who;
  final String text;

  /// Whether [text] renders as Markdown (#39) — the assistant's turns
  /// do; a person's words stay exactly as typed.
  final bool markdown;

  /// Whether the streaming cursor follows the last block.
  final bool caret;

  /// What stands where the answer will: the waiting dots (#99).
  final Widget? leading;

  /// The model's thinking, shown dimmed above the answer when the
  /// setting is on; null hides it.
  final String? reasoning;
  final String? note;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final styles = context.saiText;
    // One style for the streaming row and the finished turn, so the
    // moment an answer completes moves nothing but the cursor.
    final bodyStyle = styles.body.copyWith(
      color: SaiColors.sheetText,
      fontSize: 15,
      height: 1.5,
    );
    final mine = who == 'you';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SelectionJoin(
        separator: '\n',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              (note == null ? who : '$who · $note'),
              style: styles.eyebrowDim.copyWith(
                color: mine ? SaiColors.sheetDim : SaiColors.red,
              ),
            ),
            const SizedBox(height: 4),
            if (reasoning case final reasoning?)
              Text(
                reasoning,
                key: chatReasoningKey,
                style: styles.small.copyWith(
                  color: SaiColors.sheetDim,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ?leading,
            if (text.isNotEmpty)
              markdown
                  ? SaiMarkdown(text, style: bodyStyle, caret: caret)
                  : Text(text, style: bodyStyle),
            if (error case final error?)
              Text(error, style: styles.small.copyWith(color: SaiColors.red)),
          ],
        ),
      ),
    );
  }
}

/// The colour of a connection level: green, amber, red.
Color connectionColor(ConnectionLevel level) => switch (level) {
  ConnectionLevel.ready => SaiColors.green,
  ConnectionLevel.attention => SaiColors.amber,
  ConnectionLevel.down => SaiColors.red,
};

/// The reference's 9-point square, lit by the connection: a restrained
/// glow in the level's colour. No animation — a light, not a spinner.
class ConnectionDot extends StatelessWidget {
  const ConnectionDot({super.key, required this.level});

  final ConnectionLevel level;

  @override
  Widget build(BuildContext context) {
    final color = connectionColor(level);
    return Container(
      key: connectionDotKey,
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: color,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: 6),
        ],
      ),
    );
  }
}
