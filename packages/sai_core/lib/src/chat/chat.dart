import 'dart:async';

import 'package:riverpod/riverpod.dart';

import '../archive/archive.dart';
import '../archive/blobref.dart';
import '../archive/event.dart';
import '../context/assemble.dart';
import '../llm/call.dart';
import '../llm/failure.dart';
import '../llm/recorder.dart';
import '../llm/status.dart';
import '../providers.dart';

/// Who said a [ChatTurn].
enum ChatRole { user, assistant }

/// One entry of the transcript. An assistant turn whose call failed
/// carries the [failure] (and whatever partial [text] arrived) instead
/// of an archive [event]: the `provider.failure` line is its record.
final class ChatTurn {
  const ChatTurn({
    required this.role,
    required this.text,
    this.reasoning,
    this.event,
    this.finish,
    this.failure,
    this.tasksWithheld = false,
  });

  final ChatRole role;
  final String text;

  /// What the model thought before [text], where the backend sent it.
  final String? reasoning;

  /// Id of this turn's `chat.message` line, once written.
  final BlobRef? event;

  /// How an assistant turn ended; null for a user turn.
  final LlmFinish? finish;

  /// Why an assistant turn has no answer; null unless the call failed.
  final LlmFailure? failure;

  /// Whether the assistant answered this turn without the list.
  final bool tasksWithheld;

  bool get failed => failure != null;

  @override
  String toString() => 'ChatTurn(${role.name}, ${text.length} chars)';
}

/// The transcript and what is happening to it.
final class ChatState {
  ChatState({
    required List<ChatTurn> turns,
    this.streaming,
    this.reasoning,
    this.tasksWithheld = false,
    this.error,
  }) : turns = List.unmodifiable(turns);

  static final empty = ChatState(turns: const []);

  final List<ChatTurn> turns;

  /// The answer as it arrives; null when no call is running.
  final String? streaming;

  /// The reasoning as it arrives, while a call runs; null when none
  /// came (yet).
  final String? reasoning;

  /// Whether the running call goes without the list.
  final bool tasksWithheld;

  /// Why the last [ChatNotifier.send] did not start a call, until cleared
  /// or the next send.
  final String? error;

  bool get busy => streaming != null;

  ChatState copyWith({
    List<ChatTurn>? turns,
    String? streaming,
    String? reasoning,
    bool clearStreaming = false,
    bool? tasksWithheld,
    String? error,
    bool clearError = false,
  }) => ChatState(
    turns: turns ?? this.turns,
    streaming: clearStreaming ? null : (streaming ?? this.streaming),
    reasoning: clearStreaming ? null : (reasoning ?? this.reasoning),
    tasksWithheld: tasksWithheld ?? this.tasksWithheld,
    error: clearError ? null : (error ?? this.error),
  );
}

/// What [ChatNotifier.send] says when a call is already running.
const chatBusyError = 'still answering — Esc stops it';

/// What [ChatNotifier.send] says before the archive has opened.
const chatNotReadyError = 'opening the archive…';

/// Holds the conversation and runs each turn: assemble (ADR 0011),
/// record the user's line, call through the recorder (ADR 0007, 0010),
/// stream, record the assistant's line. One call at a time; a second
/// send while one runs is refused, not queued.
///
/// Everything is read through the container at send time, as the
/// recorder does, so a provider or policy switched mid-conversation
/// governs the next turn and never disturbs the running one.
class ChatNotifier extends Notifier<ChatState> {
  @override
  ChatState build() => ChatState.empty;

  RecordedCall? _call;
  var _generation = 0;

  /// Sends [draft] as the next user turn. Returns once the answer is
  /// complete and recorded, or once the send was refused (see
  /// [ChatState.error]). Never throws.
  Future<void> send(String draft) async {
    final container = ref.container;
    if (state.busy) return _refuse(chatBusyError);
    final message = draft.trim();
    if (message.isEmpty) return;
    final provider = container.read(activeLlmProvider);
    if (provider == null) return _refuse(noProviderStatus);
    final projection = container.read(tasksProvider).value;
    if (projection == null) return _refuse(chatNotReadyError);

    final AssembledContext assembled;
    try {
      assembled = assembleContext(
        profile: defaultProfile,
        projection: projection,
        today: container.read(todayProvider),
        history: [
          for (final turn in state.turns)
            if (turn.text.isNotEmpty)
              LlmMessage(switch (turn.role) {
                ChatRole.user => LlmRole.user,
                ChatRole.assistant => LlmRole.assistant,
              }, turn.text),
        ],
        draft: message,
      );
    } on ContextBudgetError catch (error) {
      return _refuse(error.toString());
    }

    final generation = ++_generation;
    bool current() => generation == _generation;
    // Busy from here, before the first await: a second Enter in the same
    // tick is refused rather than racing this one to the recorder.
    state = state.copyWith(streaming: '', clearError: true);
    final Archive archive;
    final LlmRecorder recorder;
    final StoredEvent said;
    try {
      archive = await container.read(archiveProvider.future);
      recorder = await container.read(llmRecorderProvider.future);
      said = await archive.append(
        EventDraft(
          type: EventTypes.chatMessage,
          actor: Actor.user,
          source: container.read(eventSourceProvider),
          payload: {'text': message},
        ),
      );
    } on Object catch (error) {
      if (current()) {
        state = state.copyWith(clearStreaming: true);
        _refuse('could not record the message: $error');
      }
      return;
    }
    if (!current()) return;
    state = state.copyWith(
      turns: [
        ...state.turns,
        ChatTurn(role: ChatRole.user, text: message, event: said.id),
      ],
    );

    final RecordedCall call;
    try {
      call = await recorder.start(provider, assembled.request);
    } on Object catch (error) {
      if (current()) {
        state = state.copyWith(clearStreaming: true);
        _refuse('the call could not start: $error');
      }
      return;
    }
    if (!current()) return call.cancel();
    _call = call;
    state = state.copyWith(tasksWithheld: call.taskContextWithheld);
    final deltas = call.deltas.listen((delta) {
      if (!current()) return;
      state = delta.reasoning
          ? state.copyWith(reasoning: call.reasoning)
          : state.copyWith(streaming: call.text);
    });
    final result = await call.done;
    await deltas.cancel();
    if (!current()) return;
    _call = null;

    ChatTurn turn;
    String? error;
    if (result.finish == LlmFinish.failed) {
      turn = ChatTurn(
        role: ChatRole.assistant,
        text: result.text,
        reasoning: result.reasoning,
        finish: result.finish,
        failure: result.failure,
        tasksWithheld: call.taskContextWithheld,
      );
    } else {
      BlobRef? event;
      try {
        final stored = await archive.append(
          EventDraft(
            type: EventTypes.chatMessage,
            actor: Actor.assistant,
            source: container.read(eventSourceProvider),
            payload: {'text': result.text, 'finish': result.finish.name},
            model: result.model,
            refs: [call.response!],
          ),
        );
        event = stored.id;
      } on Object catch (cause) {
        error = 'could not record the answer: $cause';
      }
      turn = ChatTurn(
        role: ChatRole.assistant,
        text: result.text,
        reasoning: result.reasoning,
        event: event,
        finish: result.finish,
        tasksWithheld: call.taskContextWithheld,
      );
    }
    state = state.copyWith(
      turns: [...state.turns, turn],
      clearStreaming: true,
      error: error,
    );
  }

  /// Stops the running answer; what arrived stays as the assistant's
  /// turn, marked cancelled (ADR 0007). No-op when nothing runs.
  void cancel() => _call?.cancel();

  void clearError() {
    if (state.error != null) state = state.copyWith(clearError: true);
  }

  void _refuse(String why) => state = state.copyWith(error: why);
}
