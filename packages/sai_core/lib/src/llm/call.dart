import 'dart:async';

import '../archive/event.dart';
import 'failure.dart';

enum LlmRole { system, user, assistant }

/// What task data a message or request context may quote (#105): none,
/// the compact Today/Upcoming lists a cloud provider may see, or the
/// complete catalog only a local provider ever receives. The value never
/// goes on the wire or into the archive — it exists so [LlmRequest.forCloud]
/// can drop what a cloud provider must not see (ADR 0010, 0011).
enum TaskProvenance { none, compact, catalog }

/// One turn of the conversation as sent to the model.
final class LlmMessage {
  const LlmMessage(
    this.role,
    this.text, {
    this.provenance = TaskProvenance.none,
  });

  final LlmRole role;
  final String text;

  /// What task data [text] may quote — an earlier answer given with the
  /// compact lists or the catalog in view. See [TaskProvenance].
  final TaskProvenance provenance;

  /// `text`, not `content`: the archive already says `chat.message.text`.
  Map<String, Object?> toJson() => {'role': role.name, 'text': text};
}

/// What a caller asks a provider for. Immutable; [messages] is never empty.
///
/// [taskContext] is the task list as the caller wants the model to see it,
/// carried apart from [messages] so the privacy policy (#27) can withhold
/// it without reading prose. Only the recorder turns it into a message
/// ([sent]); a provider never sees the field.
final class LlmRequest {
  LlmRequest({
    required List<LlmMessage> messages,
    this.model,
    this.maxTokens,
    this.temperature,
    this.taskContext,
    TaskProvenance? taskContextProvenance,
    this.reasoning,
  }) : messages = List.unmodifiable(messages),
       taskContextProvenance =
           taskContextProvenance ??
           (taskContext == null
               ? TaskProvenance.none
               : TaskProvenance.compact) {
    if (messages.isEmpty) {
      throw ArgumentError('a request needs at least one message');
    }
    if (taskContext != null && taskContext!.isEmpty) {
      throw ArgumentError('taskContext, when given, must not be empty');
    }
    if ((taskContext == null) !=
        (this.taskContextProvenance == TaskProvenance.none)) {
      throw ArgumentError(
        'taskContextProvenance must be none exactly when there is no '
        'taskContext, got ${this.taskContextProvenance.name} with'
        '${taskContext == null ? 'out' : ''} a context',
      );
    }
    if (model != null && model!.isEmpty) {
      throw ArgumentError('model, when given, must not be empty');
    }
    if (maxTokens != null && maxTokens! < 1) {
      throw ArgumentError('maxTokens must be positive, got $maxTokens');
    }
    final t = temperature;
    if (t != null && !(t >= 0 && t.isFinite)) {
      throw ArgumentError('temperature must be a finite non-negative number');
    }
  }

  final List<LlmMessage> messages;

  /// Overrides the provider's default model.
  final String? model;
  final int? maxTokens;
  final double? temperature;

  /// Personal data the policy may withhold; see the class note.
  final String? taskContext;

  /// What shape [taskContext] is (#105): [TaskProvenance.none] exactly
  /// when there is no context — the constructor enforces it. A catalog
  /// context can never reach a cloud provider, whatever the switch says.
  final TaskProvenance taskContextProvenance;

  /// Whether the model may think before it answers: false asks the
  /// backend not to (`reasoning_effort: none` on an OpenAI-compatible
  /// wire); null leaves it to the backend's default.
  final bool? reasoning;

  /// The request as a cloud provider may receive it (#105). Catalog data
  /// never goes to the cloud: a catalog [taskContext] and catalog-flagged
  /// history are dropped whatever the arguments say. With
  /// [sendTaskContext] false the (compact) context is dropped too; with
  /// [keepCompactHistory] false, compact-flagged history goes with it.
  /// A dropped answer takes the user question just before it along — a
  /// pair goes as a whole (ADR 0011), so the governed history never
  /// carries two user lines in a row. The recorder is the only
  /// production caller (ADR 0010).
  LlmRequest forCloud({
    required bool sendTaskContext,
    required bool keepCompactHistory,
  }) {
    final context =
        sendTaskContext && taskContextProvenance == TaskProvenance.compact;
    final kept = <LlmMessage>[];
    for (final m in messages) {
      final keep = switch (m.provenance) {
        TaskProvenance.none => true,
        TaskProvenance.compact => keepCompactHistory,
        TaskProvenance.catalog => false,
      };
      if (keep) {
        kept.add(m);
      } else if (m.role == LlmRole.assistant &&
          kept.isNotEmpty &&
          kept.last.role == LlmRole.user) {
        kept.removeLast();
      }
    }
    return LlmRequest(
      messages: kept,
      model: model,
      maxTokens: maxTokens,
      temperature: temperature,
      taskContext: context ? taskContext : null,
      taskContextProvenance: context
          ? taskContextProvenance
          : TaskProvenance.none,
      reasoning: reasoning,
    );
  }

  /// The same request with the reasoning switch left to the backend —
  /// for a backend that rejected the switch.
  LlmRequest withoutReasoning() => LlmRequest(
    messages: messages,
    model: model,
    maxTokens: maxTokens,
    temperature: temperature,
    taskContext: taskContext,
    taskContextProvenance: taskContextProvenance,
  );

  /// The messages as they go on the wire: [taskContext], when present, as
  /// a `system` message after any leading system messages and before the
  /// first other one — instructions first, then the data, then the talk.
  List<LlmMessage> get sent {
    final context = taskContext;
    if (context == null) return messages;
    var at = 0;
    while (at < messages.length && messages[at].role == LlmRole.system) {
      at++;
    }
    return List.unmodifiable([
      ...messages.take(at),
      LlmMessage(LlmRole.system, context, provenance: taskContextProvenance),
      ...messages.skip(at),
    ]);
  }

  /// The request a provider is started with: the [sent] messages and
  /// no task-context field.
  LlmRequest assembled() => LlmRequest(
    messages: sent,
    model: model,
    maxTokens: maxTokens,
    temperature: temperature,
    reasoning: reasoning,
  );
}

/// One streamed piece of the answer. A class, not a string: later
/// tickets add other kinds of deltas without touching every client.
final class LlmDelta {
  const LlmDelta(this.text, {this.reasoning = false});

  final String text;

  /// The model thinking aloud before it answers (LM Studio, DeepSeek and
  /// kin send it apart from the answer). Never part of [LlmResult.text].
  final bool reasoning;
}

/// Token counts and timings as the backend reports them; every field is
/// optional because every backend reports a different subset.
final class LlmUsage {
  const LlmUsage({
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.tokensPerSecond,
    this.cost,
  });

  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;

  /// llama.cpp `timings` and friends, where reported (#22).
  final double? tokensPerSecond;

  /// What the backend says the call cost, in its own currency units
  /// (OpenRouter reports dollars). Only ever what was reported — nothing
  /// in sai estimates a price (#30).
  final double? cost;

  Map<String, Object?> toJson() => {
    if (promptTokens != null) 'prompt_tokens': promptTokens,
    if (completionTokens != null) 'completion_tokens': completionTokens,
    if (totalTokens != null) 'total_tokens': totalTokens,
    if (tokensPerSecond != null) 'tokens_per_second': tokensPerSecond,
    if (cost != null) 'cost': cost,
  };
}

/// Why a call ended. Cancellation is an outcome, not a failure.
enum LlmFinish { stop, length, cancelled, failed }

/// The one terminal value of a call. [failure] is present exactly when
/// [finish] is [LlmFinish.failed] — the constructor refuses anything else.
final class LlmResult {
  LlmResult({
    required this.text,
    required this.finish,
    required this.model,
    this.usage,
    this.failure,
    this.reasoning,
  }) {
    if (reasoning != null && reasoning!.isEmpty) {
      throw ArgumentError('reasoning must be null or non-empty');
    }
    if ((finish == LlmFinish.failed) != (failure != null)) {
      throw ArgumentError(
        'a result carries a failure exactly when its finish is failed '
        '(finish: ${finish.name}, failure: $failure)',
      );
    }
  }

  /// Exactly the concatenation of the deltas the call emitted.
  final String text;
  final LlmFinish finish;

  /// Lineage for the archive: provider, model id, backend version and
  /// request id where exposed. The envelope's own [ModelRef].
  final ModelRef model;
  final LlmUsage? usage;

  /// Non-null iff [finish] is [LlmFinish.failed].
  final LlmFailure? failure;

  /// The reasoning deltas joined, where the backend sent any.
  final String? reasoning;

  @override
  String toString() =>
      'LlmResult(${finish.name}, ${text.length} chars, $model'
      '${failure == null ? '' : ', $failure'})';
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

  /// The call's lineage: what was asked for, until a provider learns
  /// what the backend answered with (a loaded-model request) and replaces
  /// it — so a cancelled call is archived under the model that produced
  /// its partial text, too.
  ModelRef model;

  /// Runs once, after [cancel] has finished the call — the provider's
  /// chance to abort its transport.
  final void Function()? onCancel;
  final _deltas = StreamController<LlmDelta>();
  final _done = Completer<LlmResult>();
  final _text = StringBuffer();
  final _reasoning = StringBuffer();

  late final LlmCall call;

  /// Provider-reported usage so far; used when [cancel] builds the result.
  LlmUsage? usage;

  bool get isDone => _done.isCompleted;
  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  /// The text emitted so far.
  String get text => _text.toString();

  /// The reasoning emitted so far; null when there was none — the form
  /// [LlmResult.reasoning] takes.
  String? get reasoning => _reasoning.isEmpty ? null : _reasoning.toString();

  /// Emits one delta. Ignored once the call is done.
  void add(String text) {
    if (isDone) return;
    _text.write(text);
    _deltas.add(LlmDelta(text));
  }

  /// Emits one reasoning delta, kept apart from [text]. Ignored once
  /// the call is done.
  void addReasoning(String text) {
    if (isDone) return;
    _reasoning.write(text);
    _deltas.add(LlmDelta(text, reasoning: true));
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

  /// Runs the provider's body under the contract: whatever [body] does —
  /// throw, return without finishing, finish with the wrong text — the
  /// call ends with exactly one result. A throw becomes an internal
  /// failure carrying the text so far; a body that returns while the
  /// call is still open is one too. Providers put their whole async
  /// work here instead of firing it unawaited.
  void run(Future<void> Function() body) {
    unawaited(
      Future<void>.sync(body).then(
        (_) {
          if (isDone) return;
          _fail('provider returned without finishing the call');
        },
        onError: (Object error) {
          if (isDone) return;
          // The type, never the text: an exception from a transport can
          // quote a header or a URL, and this message goes to the archive.
          _fail('provider threw: ${error.runtimeType}');
        },
      ),
    );
  }

  void _fail(String message) {
    _complete(
      LlmResult(
        text: text,
        finish: LlmFinish.failed,
        model: model,
        usage: usage,
        failure: LlmFailure(LlmFailureKind.internal, message),
        reasoning: reasoning,
      ),
    );
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
        reasoning: reasoning,
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
