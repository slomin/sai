import 'package:nocterm/nocterm.dart';
import 'package:sai_core/sai_core.dart';

/// The composer's placeholder; names the key that reaches it.
const chatPlaceholder = 'Ask sai… Tab here, Enter sends';

/// The conversation (#34) in the terminal: the transcript from
/// [chatProvider] above a one-line composer. Plain text, one row per
/// line; the newest text stays in view as it streams.
class ChatPane extends StatelessComponent {
  const ChatPane({
    super.key,
    required this.state,
    required this.showReasoning,
    required this.focused,
    required this.scroll,
    required this.input,
    required this.onSubmit,
  });

  /// Whether the pane is worth its rows: focused, or holding a
  /// conversation. Collapsed, it is just the composer line, so the lists
  /// keep the screen until chat is in use.
  static bool open(ChatState state, {required bool focused}) =>
      focused || state.turns.isNotEmpty || state.busy || state.error != null;

  final ChatState state;

  /// Whether the model's thinking is shown, dimmed, above its answer.
  final bool showReasoning;
  final bool focused;
  final AutoScrollController scroll;
  final TextEditingController input;
  final void Function(String) onSubmit;

  @override
  Component build(BuildContext context) {
    final field = TextField(
      controller: input,
      focused: focused,
      placeholder: chatPlaceholder,
      onSubmitted: onSubmit,
    );
    if (!open(state, focused: focused)) return field;
    final rows = <Component>[
      for (final turn in state.turns) ..._turn(turn),
      if (state.busy) ...[
        if (showReasoning && state.reasoning != null)
          Text(
            'sai thinks › ${state.reasoning!}',
            style: TextStyle(color: Colors.gray),
          ),
        Text(
          'sai${state.tasksWithheld ? ' · $tasksWithheldWord' : ''} › '
          '${state.streaming!.isEmpty ? (state.reasoning == null ? '…' : 'thinking…') : '${state.streaming!}▌'}',
        ),
      ],
      if (state.error case final error?)
        Text(error, style: TextStyle(color: Colors.yellow)),
    ];
    return Column(
      children: [
        Expanded(
          child: rows.isEmpty
              ? Text(
                  'Ask about your list — Today and Upcoming are what sai sees.',
                  style: TextStyle(color: Colors.gray),
                )
              : ListView(controller: scroll, lazy: true, children: rows),
        ),
        field,
      ],
    );
  }

  List<Component> _turn(ChatTurn turn) {
    final who = turn.role == ChatRole.user ? 'you' : 'sai';
    final notes = [
      if (turn.finish == LlmFinish.cancelled) 'cancelled',
      if (turn.finish == LlmFinish.length) 'cut short',
      if (turn.tasksWithheld) tasksWithheldWord,
      ?AssembledContext.cutNote(turn.dropped),
    ];
    final label = notes.isEmpty ? who : '$who · ${notes.join(' · ')}';
    final failure = turn.failure;
    return [
      if (showReasoning && turn.reasoning != null)
        Text(
          'sai thinks › ${turn.reasoning!}',
          style: TextStyle(color: Colors.gray),
        ),
      if (turn.text.isNotEmpty || failure == null)
        Text('$label › ${turn.text}'),
      if (failure != null)
        Text(
          '$label › failed: ${failure.kind.name} — ${failure.message}'
          '${failure.endpoint == null ? '' : ' (${failure.endpoint})'}',
          style: TextStyle(color: Colors.red),
        ),
    ];
  }
}
