import 'dart:async';

import '../archive/event.dart';
import 'failure.dart';

enum LlmRole { system, user, assistant }

/// One turn of the conversation as sent to the model.
final class LlmMessage {
  const LlmMessage(this.role, this.text);

  final LlmRole role;
  final String text;

  /// `text`, not `content`: the archive already says `chat.message.text`.
  Map<String, Object?> toJson() => {'role': role.name, 'text': text};
}

/// What a caller asks a provider for. Immutable; [messages] is never empty.
final class LlmRequest {
  LlmRequest({
    required List<LlmMessage> messages,
    this.model,
    this.maxTokens,
    this.temperature,
  }) : messages = List.unmodifiable(messages) {
    if (messages.isEmpty) {
      throw ArgumentError('a request needs at least one message');
    }
  }

  final List<LlmMessage> messages;

  /// Overrides the provider's default model.
  final String? model;
  final int? maxTokens;
  final double? temperature;
}

/// One streamed piece of the answer. A class, not a string: later
/// tickets add other kinds of deltas without touching every client.
final class LlmDelta {
  const LlmDelta(this.text);

  final String text;
}

/// Token counts and timings as the backend reports them; every field is
/// optional because every backend reports a different subset.
final class LlmUsage {
  const LlmUsage({
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.tokensPerSecond,
  });

  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;

  /// llama.cpp `timings` and friends, where reported (#22).
  final double? tokensPerSecond;

  Map<String, Object?> toJson() => {
    if (promptTokens != null) 'prompt_tokens': promptTokens,
    if (completionTokens != null) 'completion_tokens': completionTokens,
    if (totalTokens != null) 'total_tokens': totalTokens,
    if (tokensPerSecond != null) 'tokens_per_second': tokensPerSecond,
  };
}

/// Why a call ended. Cancellation is an outcome, not a failure.
enum LlmFinish { stop, length, cancelled, failed }

/// The one terminal value of a call.
final class LlmResult {
  const LlmResult({
    required this.text,
    required this.finish,
    required this.model,
    this.usage,
    this.failure,
  });

  /// Exactly the concatenation of the deltas the call emitted.
  final String text;
  final LlmFinish finish;

  /// Lineage for the archive: provider, model id, backend version and
  /// request id where exposed. The envelope's own [ModelRef].
  final ModelRef model;
  final LlmUsage? usage;

  /// Non-null iff [finish] is [LlmFinish.failed].
  final LlmFailure? failure;
}

/// A running or finished call.
abstract interface class LlmCall {
  /// Single-subscription. Never emits an error: a failed call closes the
  /// stream and reports the failure on [done].
  Stream<LlmDelta> get deltas;

  /// Always completes, never with an error. One terminal value per call.
  Future<LlmResult> get done;

  /// Idempotent; a no-op once the call has finished.
  void cancel();
}

/// The state machine behind an [LlmCall]. Providers drive this instead
/// of writing their own, so cancellation and the "one terminal result"
/// rule have one implementation.
///
/// [cancel] finishes the call immediately — with [LlmFinish.cancelled],
/// the text accumulated so far and whatever [usage] was set — and only
/// then runs `onCancel` so the provider can abort its transport. A
/// provider that is stuck on a socket can therefore never hang `done`.
final class LlmCallController {
  LlmCallController({required this.model, this.onCancel}) {
    call = _Call(this);
  }

  final ModelRef model;

  /// Runs once, after [cancel] has finished the call — the provider's
  /// chance to abort its transport.
  final void Function()? onCancel;
  final _deltas = StreamController<LlmDelta>();
  final _done = Completer<LlmResult>();
  final _text = StringBuffer();

  late final LlmCall call;

  /// Provider-reported usage so far; used when [cancel] builds the result.
  LlmUsage? usage;

  bool get isDone => _done.isCompleted;
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  /// The text emitted so far.
  String get text => _text.toString();

  /// Emits one delta. Ignored once the call is done.
  void add(String text) {
    if (isDone) return;
    _text.write(text);
    _deltas.add(LlmDelta(text));
  }

  /// Ends the call. The first call wins; later ones are ignored.
  ///
  /// Throws [ArgumentError] when [result]'s text is not what the deltas
  /// added up to — the two must never disagree in the archive.
  void finish(LlmResult result) {
    if (isDone) return;
    if (result.text != text) {
      throw ArgumentError(
        'result text does not match the emitted deltas: '
        '"${result.text}" vs "$text"',
      );
    }
    _complete(result);
  }

  void cancel() {
    if (isDone) return;
    _cancelled = true;
    _complete(
      LlmResult(
        text: text,
        finish: LlmFinish.cancelled,
        model: model,
        usage: usage,
      ),
    );
    onCancel?.call();
  }

  void _complete(LlmResult result) {
    _done.complete(result);
    _deltas.close();
  }
}

final class _Call implements LlmCall {
  _Call(this._controller);

  final LlmCallController _controller;

  @override
  Stream<LlmDelta> get deltas => _controller._deltas.stream;

  @override
  Future<LlmResult> get done => _controller._done.future;

  @override
  void cancel() => _controller.cancel();
}
