import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../commands.dart';
import '../theme/motion.dart';
import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';

/// The chat pane's input, so tests and Cmd+J can find it.
const chatFieldKey = Key('chat-field');

/// The transcript list.
const chatTranscriptKey = Key('chat-transcript');

/// A reasoning block, when shown.
const chatReasoningKey = Key('chat-reasoning');

/// The button that sends the draft, and the one that stops an answer.
const chatSendKey = Key('chat-send');
const chatStopKey = Key('chat-stop');

/// The band's header, which also toggles it.
const assistantHeaderKey = Key('assistant-header');

/// What the empty band says.
const chatEmptyHint =
    'Ask about your list — what is due, what is coming up, how the day '
    'looks. The assistant reads Today and Upcoming; it cannot change them.';

/// How tall the open band's body is for a main column of [height]: about
/// two fifths, within bounds, so a short window keeps its list.
double assistantBandHeight(double height) => (height * 0.4).clamp(160.0, 360.0);

/// The ink band (#72): the assistant on a different surface from the
/// list, docked under it. The header names the provider and stays when
/// the band is tucked away (⌘J); the body is the conversation (#34) —
/// the transcript from [chatProvider], the answer as it streams, and the
/// composer. Opening and closing animate through [SaiMotion]; the draft
/// and focus live in `commands.dart`, so nothing is lost either way.
class AssistantBand extends ConsumerWidget {
  const AssistantBand({super.key, required this.bodyHeight});

  /// The open body's height ([assistantBandHeight] of the column).
  final double bodyHeight;

  Widget body(bool open) => open
      ? SizedBox(height: bodyHeight, child: const _ChatBody())
      : const SizedBox(width: double.infinity);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(chatVisibleProvider);
    final commands = AppCommands.of(context);
    final status = ref.watch(llmStatusProvider);
    return Container(
      decoration: const BoxDecoration(
        color: SaiColors.sheetBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(status: status, open: open, onTap: commands.toggleChat),
          // A zero-length AnimatedSize still animates — and marks itself
          // dirty during layout — so under Reduce Motion the body just is.
          if (SaiMotion.reduced(context))
            body(open)
          else
            AnimatedSize(
              duration: SaiDurations.band,
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: body(open),
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.status,
    required this.open,
    required this.onTap,
  });

  final String status;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mono = context.saiText.meta;
    return Semantics(
      button: true,
      label: open ? 'Tuck the assistant away' : 'Open the assistant',
      child: InkWell(
        key: assistantHeaderKey,
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                Container(width: 9, height: 9, color: SaiColors.red),
                const SizedBox(width: 10),
                Text(
                  'ASSISTANT',
                  style: mono.copyWith(
                    color: SaiColors.sheetText,
                    fontWeight: FontWeight.w700,
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
    final commands = AppCommands.of(context);
    final text = context.saiText;
    return Column(
      children: [
        Expanded(
          child: state.turns.isEmpty && !state.busy
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
              : ListView(
                  key: chatTranscriptKey,
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  children: [
                    for (final turn in state.turns)
                      _TurnRow(turn, reasoningOn: reasoningOn),
                    if (state.busy)
                      _Row(
                        who: 'sai',
                        reasoning: reasoningOn ? state.reasoning : null,
                        text: state.streaming!.isEmpty
                            ? (state.reasoning == null ? '…' : 'thinking…')
                            : '${state.streaming!}▌',
                        note: state.tasksWithheld ? tasksWithheldWord : null,
                      ),
                  ],
                ),
        ),
        if (state.error case final error?)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                error,
                style: text.small.copyWith(color: SaiColors.red),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: chatFieldKey,
                  controller: ref.watch(chatDraftProvider),
                  focusNode: ref.watch(chatFocusProvider),
                  onSubmitted: (_) => commands.sendChat(),
                  style: text.body.copyWith(color: SaiColors.sheetText),
                  decoration: InputDecoration(
                    hintText: 'Ask sai…',
                    hintStyle: text.body.copyWith(color: SaiColors.sheetDim),
                    fillColor: SaiColors.sheetCard,
                    enabledBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: SaiColors.sheetRule),
                      borderRadius: BorderRadius.all(
                        Radius.circular(SaiRadius.medium),
                      ),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: SaiColors.sheetRuleMid),
                      borderRadius: BorderRadius.all(
                        Radius.circular(SaiRadius.medium),
                      ),
                    ),
                    suffixIcon: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(
                        '⏎ SEND · ⇧⏎ NEWLINE',
                        style: context.saiText.chip.copyWith(
                          color: SaiColors.sheetDim,
                        ),
                      ),
                    ),
                    suffixIconConstraints: const BoxConstraints(minWidth: 0),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              if (state.busy)
                FilledButton(
                  key: chatStopKey,
                  onPressed: commands.cancelChat,
                  style: FilledButton.styleFrom(
                    backgroundColor: SaiColors.sheetCard,
                    foregroundColor: SaiColors.sheetText,
                  ),
                  child: const Text('Stop'),
                )
              else
                FilledButton(
                  key: chatSendKey,
                  onPressed: commands.sendChat,
                  style: FilledButton.styleFrom(
                    backgroundColor: SaiColors.red,
                    foregroundColor: SaiColors.white,
                  ),
                  child: const Text('Send'),
                ),
            ],
          ),
        ),
      ],
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
      note: notes.isEmpty ? null : notes.join(' · '),
      error: failure == null ? null : chatFailureLine(failure),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.who,
    required this.text,
    this.reasoning,
    this.note,
    this.error,
  });

  final String who;
  final String text;

  /// The model's thinking, shown dimmed above the answer when the
  /// setting is on; null hides it.
  final String? reasoning;
  final String? note;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final styles = context.saiText;
    final mine = who == 'you';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
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
          if (text.isNotEmpty)
            Text(
              text,
              style: styles.body.copyWith(
                color: SaiColors.sheetText,
                fontSize: 15,
                height: 1.5,
              ),
            ),
          if (error case final error?)
            Text(error, style: styles.small.copyWith(color: SaiColors.red)),
        ],
      ),
    );
  }
}
