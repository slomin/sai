import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'commands.dart';

/// The chat pane's input, so tests and Cmd+J can find it.
const chatFieldKey = Key('chat-field');

/// The transcript list.
const chatTranscriptKey = Key('chat-transcript');

/// A reasoning block, when shown.
const chatReasoningKey = Key('chat-reasoning');

/// The button that sends the draft, and the one that stops an answer.
const chatSendKey = Key('chat-send');
const chatStopKey = Key('chat-stop');

/// What the empty pane says.
const chatEmptyHint =
    'Ask about your list — what is due, what is coming up, how the day '
    'looks. The assistant reads Today and Upcoming; it cannot change them.';

/// The conversation (#34): the transcript from [chatProvider], the answer
/// as it streams, and the composer. Plain text for now — rendering is
/// #39. The draft and focus live in `commands.dart` so they survive the
/// pane unmounting below its breakpoint; the transcript lives in core.
class ChatPane extends ConsumerStatefulWidget {
  const ChatPane({super.key});

  @override
  ConsumerState<ChatPane> createState() => _ChatPaneState();
}

class _ChatPaneState extends ConsumerState<ChatPane> {
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
    final theme = Theme.of(context);
    return Column(
      children: [
        Expanded(
          child: state.turns.isEmpty && !state.busy
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      chatEmptyHint,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                )
              : ListView(
                  key: chatTranscriptKey,
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
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
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              error,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: chatFieldKey,
                  controller: ref.watch(chatDraftProvider),
                  focusNode: ref.watch(chatFocusProvider),
                  onSubmitted: (_) => commands.sendChat(),
                  decoration: const InputDecoration(
                    hintText: 'Ask sai…',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (state.busy)
                TextButton(
                  key: chatStopKey,
                  onPressed: commands.cancelChat,
                  child: const Text('Stop'),
                )
              else
                TextButton(
                  key: chatSendKey,
                  onPressed: commands.sendChat,
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
    final theme = Theme.of(context);
    final label = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.primary,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(note == null ? who : '$who · $note', style: label),
          if (reasoning case final reasoning?)
            Text(
              reasoning,
              key: chatReasoningKey,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
                fontStyle: FontStyle.italic,
              ),
            ),
          if (text.isNotEmpty) Text(text),
          if (error case final error?)
            Text(
              error,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }
}
