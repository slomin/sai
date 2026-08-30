import 'dart:async';

import 'package:riverpod/riverpod.dart';

import '../archive/archive.dart';
import '../archive/blobref.dart';
import '../archive/event.dart';
import '../context/assemble.dart';
import '../llm/call.dart';
import '../llm/failure.dart';
import '../llm/privacy.dart';
import '../llm/provider.dart';
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
    this.provenance = TaskProvenance.none,
    this.dropped = const [],
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

  /// What task data an assistant turn's call carried (#105): its words
  /// may quote what it saw, so this is what a later request's history
  /// inherits — and what the recorder drops from a cloud call. None for
  /// user turns and for answers given with the context withheld.
  final TaskProvenance provenance;

  /// What the budget left out of this turn's request
  /// ([AssembledContext.dropped]); empty when nothing was cut.
  final List<String> dropped;

  bool get failed => failure != null;

  @override
  String toString() => 'ChatTurn(${role.name}, ${text.length} chars)';
}

/// The notes both clients put beside an assistant turn's name, in a
/// fixed order: how it ended, what it went without, what was cut.
List<String> turnNotes(ChatTurn turn) => [
  if (turn.finish == LlmFinish.cancelled) 'cancelled',
  if (turn.finish == LlmFinish.length) 'cut short',
  if (turn.tasksWithheld) tasksWithheldWord,
  ?AssembledContext.cutNote(turn.dropped),
];

/// The failed turn's line, the same words in every client and the
/// Providers dialog: kind, message, origin.
String chatFailureLine(LlmFailure failure) =>
    'failed: ${failure.kind.name} — ${failure.message}'
    '${failure.endpoint == null ? '' : ' (${failure.endpoint})'}';

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

  /// Why the last [ChatNotifier.send] did not start a call, until the
  /// next send or the running turn ends.
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
  ChatState build() {
    ref.onDispose(() {
      _disposed = true;
      _call?.cancel();
    });
    return ChatState.empty;
  }

  RecordedCall? _call;
  var _generation = 0;
  var _disposed = false;

  /// Set by [cancel] while a turn is being prepared and has no call yet;
  /// the turn then ends before anything is sent.
  var _cancelRequested = false;

  /// The window a turn is assembled for. A constant until the budget
  /// follows the endpoint's context window (ADR 0011); tests set it.
  ContextBudget budget = defaultContextBudget;

  /// Writes [next] unless the notifier is gone — a call that outlives
  /// its container must not throw from a stream callback.
  void _set(ChatState next) {
    if (!_disposed) state = next;
  }

  /// Sends [draft] as the next user turn. Completes once the answer is
  /// recorded, or once the send was refused — [ChatState.error] says so
  /// and [wasAccepted] tells a client whether to keep the draft. Never
  /// throws.
  Future<bool> send(String draft) async {
    final container = ref.container;
    if (state.busy) return _refuse(chatBusyError);
    final message = draft.trim();
    if (message.isEmpty) return false;
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
        history: _history(),
        draft: message,
        budget: budget,
        // Off asks the backend not to think; on leaves it to the model.
        reasoning: container.read(reasoningProvider) ? null : false,
        // A local model sees the whole collection; a cloud one at most
        // the compact lists (#105).
        shape: provider.privacy == LlmPrivacy.local
            ? TaskContextShape.catalog
            : TaskContextShape.compact,
      );
    } on ContextBudgetError catch (error) {
      return _refuse(error.toString());
    } on ContextSizeError catch (error) {
      // Refused before anything was written: no orphan chat.message.
      return _refuse(error.toString());
    }

    final generation = ++_generation;
    bool current() => generation == _generation && !_disposed;
    _cancelRequested = false;
    // Busy from here, before the first await: a second Enter in the same
    // tick is refused rather than racing this one to the recorder. The
    // withheld flag belongs to this call, not the last one.
    _set(state.copyWith(streaming: '', tasksWithheld: false, clearError: true));
    final Archive archive;
    final LlmRecorder recorder;
    final StoredEvent said;
    try {
      archive = await container.read(archiveProvider.future);
      recorder = await container.read(llmRecorderProvider.future);
      if (_cancelRequested) return _abandon(current);
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
        _set(state.copyWith(clearStreaming: true));
        _refuse('could not record the message: $error');
      }
      return false;
    }
    if (!current()) return false;
    _set(
      state.copyWith(
        turns: [
          ...state.turns,
          ChatTurn(role: ChatRole.user, text: message, event: said.id),
        ],
      ),
    );
    if (_cancelRequested) return _abandon(current);

    final RecordedCall call;
    try {
      call = await recorder.start(provider, assembled.request);
    } on Object catch (error) {
      if (current()) {
        _set(state.copyWith(clearStreaming: true));
        _refuse('the call could not start: $error');
      }
      return false;
    }
    if (!current()) {
      call.cancel();
      return false;
    }
    _call = call;
    if (_cancelRequested) call.cancel();
    _set(state.copyWith(tasksWithheld: call.taskContextWithheld));
    final deltas = call.deltas.listen((delta) {
      if (!current()) return;
      _set(
        delta.reasoning
            ? state.copyWith(reasoning: call.reasoning)
            : state.copyWith(streaming: call.text),
      );
    });
    final result = await call.done;
    await deltas.cancel();
    if (!current()) return false;
    _call = null;

    ChatTurn turn;
    String? error;
    if (result.finish == LlmFinish.failed) {
      // The header's light learns of it now, not on its next timer.
      container.read(connectionProvider.notifier).callFailed(result.failure!);
      turn = ChatTurn(
        role: ChatRole.assistant,
        text: result.text,
        reasoning: result.reasoning,
        finish: result.finish,
        failure: result.failure,
        tasksWithheld: call.taskContextWithheld,
        provenance: call.taskContextWithheld
            ? TaskProvenance.none
            : assembled.request.taskContextProvenance,
        dropped: assembled.dropped,
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
        provenance: call.taskContextWithheld
            ? TaskProvenance.none
            : assembled.request.taskContextProvenance,
        dropped: assembled.dropped,
      );
    }
    if (!current()) return true;
    _set(
      state.copyWith(
        turns: [...state.turns, turn],
        clearStreaming: true,
        // A refusal raised during the turn ends with it.
        error: error,
        clearError: error == null,
      ),
    );
    return true;
  }

  /// The conversation as the model may see it: user and assistant turns
  /// in pairs, so a template that insists on alternation is never given
  /// two user lines in a row. A pair goes as a whole — an answer that
  /// never came (cancelled before its first token, failed) takes its
  /// question with it — and an answer given with task data in view
  /// carries its provenance for the recorder to govern (ADR 0011, #105).
  List<LlmMessage> _history() {
    final turns = state.turns;
    final out = <LlmMessage>[];
    for (var i = 0; i + 1 < turns.length; i += 2) {
      final question = turns[i];
      final answer = turns[i + 1];
      if (question.role != ChatRole.user ||
          answer.role != ChatRole.assistant ||
          answer.text.isEmpty) {
        continue;
      }
      out
        ..add(LlmMessage(LlmRole.user, question.text))
        ..add(
          LlmMessage(
            LlmRole.assistant,
            answer.text,
            provenance: answer.provenance,
          ),
        );
    }
    return out;
  }

  /// Ends a turn that was stopped before its call existed: not busy,
  /// nothing sent, the user's line (if written) stays as it is.
  bool _abandon(bool Function() current) {
    if (current()) _set(state.copyWith(clearStreaming: true));
    return false;
  }

  /// Stops the running answer; what arrived stays as the assistant's
  /// turn, marked cancelled (ADR 0007). Before the call exists, the turn
  /// ends without one. No-op when nothing runs.
  void cancel() {
    if (!state.busy) return;
    final call = _call;
    if (call == null) {
      _cancelRequested = true;
    } else {
      call.cancel();
    }
  }

  void clearError() {
    if (state.error != null) _set(state.copyWith(clearError: true));
  }

  bool _refuse(String why) {
    _set(state.copyWith(error: why));
    return false;
  }
}
