import 'dart:async';
import 'dart:convert';

import '../archive/archive.dart';
import '../archive/blobref.dart';
import '../archive/event.dart';
import '../context/hash.dart';
import '../settings/endpoint.dart';
import 'call.dart';
import 'failure.dart';
import 'fallback.dart';
import 'privacy.dart';
import 'provider.dart';

/// The most a recorded payload takes once JSON-encoded. Half the
/// archive's line cap, leaving room for the envelope; text is cut to fit
/// this, measured after encoding, so escapes cannot push a line over.
const maxRecordedTextBytes = 512 << 10;

/// The `provider.request` payload as recorded: the [request]'s messages
/// with `context_hash` [hash] (ADR 0007, 0011). Public so assembly can
/// measure a turn with the recorder's own encoder before anything is
/// written (#105).
Map<String, Object?> recordedRequestPayload(LlmRequest request, BlobRef hash) =>
    {
      'messages': [for (final m in request.messages) m.toJson()],
      if (request.maxTokens != null) 'max_tokens': request.maxTokens,
      if (request.temperature != null) 'temperature': request.temperature,
      // The explicit effort, `none` included; absent when the model's
      // default was left to stand (#26). Older lines say `reasoning: false`
      // for what is now `none`; they stay as written.
      if (request.reasoningEffort case final effort?)
        'reasoning_effort': effort.word,
      if (request.responseSchema case final schema?)
        'response_format': schema.toWire(),
      'context_hash': hash.toString(),
    };

/// The exact bytes [request]'s `provider.request` payload takes once
/// recorded — assembled, hashed and JSON-encoded exactly as
/// [LlmRecorder.start] measures it. For a local provider this is the
/// recorded size to the byte; for a cloud one it is an upper bound (the
/// policy can only shrink the request).
int recordedRequestBytes(LlmRequest request) {
  final sent = request.assembled();
  final payload = recordedRequestPayload(sent, contextHash(sent.messages));
  return utf8.encode(jsonEncode(payload)).length;
}

/// The most of a failure message that is recorded.
const maxRecordedMessageBytes = 4 << 10;

/// The most reasoning a response line keeps — a quarter of the text
/// cap, so thinking never crowds out the answer it led to.
const maxRecordedReasoningBytes = 128 << 10;

/// The single write path for provider traffic: every call through here
/// lands in the archive as a request line, a response or failure line,
/// and a usage line — before [RecordedCall.done] completes. See the
/// "Provider traffic" section of `docs/archive/event-log-v0.md`.
///
/// The provider is passed per call, not held, so switching the active
/// provider can never disturb a call already running. The privacy policy
/// (#27) is applied here and nowhere else: [policy] is read per call, so a
/// switch flipped mid-session governs the next request, not a rebuild.
final class LlmRecorder {
  LlmRecorder({
    required this.archive,
    required this.source,
    required this.clock,
    required this.policy,
  });

  final Archive archive;

  /// The policy as it stands when a call starts.
  final PrivacyPolicy Function() policy;

  /// The `source` written on every line, e.g. [EventSources.app].
  final String source;
  final DateTime Function() clock;

  /// Decides what [request] may carry to [provider], appends
  /// `policy.fallback` when the preference order passed something over to
  /// reach it (#62) and `policy.decision` for a cloud provider, then
  /// `provider.request`, then starts [provider] with the request as
  /// recorded. Returns once the request line is in the archive — a crash
  /// after that still leaves the request on record.
  ///
  /// [skipped] is what the resolver walked past, in order; empty — the
  /// default — means the first choice answered and no fallback line is
  /// written. A caller that names a provider itself (the Providers page's
  /// Test) passes none: it is testing that provider, not the order.
  ///
  /// Throws [ArgumentError], before the provider is touched, when the
  /// request is too large to record: what cannot be recorded is not sent.
  Future<RecordedCall> start(
    LlmProvider provider,
    LlmRequest request, {
    List<SkippedProvider> skipped = const [],
  }) async {
    final decision = policy().decide(provider.privacy, request);
    // Local goes untouched; a cloud request is governed even when there
    // is nothing to withhold — task-bearing history follows the switch,
    // and catalog turns never go to the cloud at all (#105).
    final governed = decision == null
        ? request
        : request.forCloud(
            sendTaskContext: !decision.withheld,
            keepCompactHistory: decision.shareTasks,
          );
    final sent = governed.assembled();
    final hash = contextHash(sent.messages);
    final payload = recordedRequestPayload(sent, hash);
    if (utf8.encode(jsonEncode(payload)).length > maxRecordedTextBytes) {
      throw ArgumentError(
        'request exceeds $maxRecordedTextBytes bytes and would not be '
        'recorded, so it is not sent',
      );
    }
    final target = ModelRef(
      provider: provider.id,
      id: request.model ?? provider.defaultModel,
    );
    final started = clock();
    // What was passed over goes first, then the decision: a crash between
    // any two of them leaves the policy's word on record, and the request
    // refers back to both.
    BlobRef? fell;
    if (skipped.isNotEmpty) {
      final stored = await archive.append(
        EventDraft(
          type: EventTypes.policyFallback,
          actor: Actor.system,
          source: source,
          payload: {
            'first': skipped.first.id,
            'chosen': provider.id,
            'skipped': [for (final skip in skipped) skip.toJson()],
          },
          model: target,
        ),
      );
      fell = stored.id;
    }
    BlobRef? decided;
    if (decision != null) {
      final stored = await archive.append(
        EventDraft(
          type: EventTypes.policyDecision,
          actor: Actor.system,
          source: source,
          payload: decision.toJson(),
          model: target,
        ),
      );
      decided = stored.id;
    }
    final stored = await archive.append(
      EventDraft(
        type: EventTypes.providerRequest,
        actor: Actor.system,
        source: source,
        payload: payload,
        model: target,
        refs: [?fell, ?decided],
      ),
    );
    LlmCall call;
    try {
      call = provider.start(sent);
    } catch (error) {
      call = _FailedCall(
        LlmResult(
          text: '',
          finish: LlmFinish.failed,
          model: target,
          // Type only: exception text may quote a key, a header, a URL.
          failure: LlmFailure(
            LlmFailureKind.internal,
            'provider.start threw: ${error.runtimeType}',
          ),
        ),
      );
    }
    final recorded = RecordedCall._(
      stored.id,
      call,
      decision: decided,
      fallback: fell,
      contextHash: hash,
      taskContextWithheld: decision?.withheld ?? false,
    );
    unawaited(_record(recorded, started));
    return recorded;
  }

  Future<void> _record(RecordedCall recorded, DateTime started) async {
    Object? streamError;
    final subscription = recorded._call.deltas.listen(
      recorded._add,
      onError: (Object error) {
        streamError ??= error;
        recorded._call.cancel();
      },
      cancelOnError: false,
    );
    var result = await recorded._call.done;
    await subscription.cancel();
    if (streamError != null) {
      result = LlmResult(
        text: recorded.text,
        reasoning: result.reasoning,
        finish: LlmFinish.failed,
        model: result.model,
        usage: result.usage,
        failure: LlmFailure(
          LlmFailureKind.internal,
          'provider deltas stream errored: ${streamError.runtimeType}',
        ),
      );
    }
    final ended = clock();
    final durationMs = ended.difference(started).inMilliseconds;
    final failed = result.finish == LlmFinish.failed;
    final failure = result.failure;
    final payload = failed
        ? _fitted(
            {
              ...failure!.toJson(),
              'message': _clipBytes(failure.message, maxRecordedMessageBytes),
              if (failure.endpoint != null)
                'endpoint': normalisedEndpoint(failure.endpoint!),
              ..._reasoningFields(result.reasoning),
            },
            result.text,
            omitEmpty: true,
          )
        : _fitted({
            'finish': result.finish.name,
            ..._reasoningFields(result.reasoning),
          }, result.text);
    final outcome = EventDraft(
      type: failed ? EventTypes.providerFailure : EventTypes.providerResponse,
      actor: failed ? Actor.system : Actor.assistant,
      source: source,
      payload: payload,
      model: result.model,
      refs: [recorded.request],
    );
    // The archive is the product: a line it refuses is a failed call from
    // the caller's point of view, reported on done like any other — never
    // as an error on a future nobody is obliged to await.
    try {
      final stored = await archive.append(outcome);
      if (failed) {
        recorded._failure = stored.id;
      } else {
        recorded._response = stored.id;
      }
    } catch (error) {
      recorded._archiveError = error;
    }
    try {
      final stored = await archive.append(
        EventDraft(
          type: EventTypes.providerUsage,
          actor: Actor.system,
          source: source,
          payload: {
            'finish': result.finish.name,
            'duration_ms': durationMs < 0 ? 0 : durationMs,
            ...?result.usage?.toJson(),
          },
          model: result.model,
          refs: [recorded.request, ?recorded.response],
        ),
      );
      recorded._usage = stored.id;
    } catch (error) {
      recorded._archiveError ??= error;
    }
    final archiveError = recorded._archiveError;
    recorded._finish(
      archiveError == null
          ? result
          : LlmResult(
              text: result.text,
              reasoning: result.reasoning,
              finish: LlmFinish.failed,
              model: result.model,
              usage: result.usage,
              failure: LlmFailure(
                LlmFailureKind.archive,
                'the archive refused to record the call: $archiveError',
              ),
            ),
    );
  }

  /// `reasoning`, clipped to [maxRecordedReasoningBytes] with
  /// `reasoning_truncated` holding the original length when cut; nothing
  /// when the backend sent none.
  static Map<String, Object?> _reasoningFields(String? reasoning) {
    if (reasoning == null) return const {};
    final clipped = _clipBytes(reasoning, maxRecordedReasoningBytes);
    return {
      'reasoning': clipped,
      if (clipped.length != reasoning.length)
        'reasoning_truncated': utf8.encode(reasoning).length,
    };
  }

  /// The origin of [endpoint] — `scheme://host[:port]` — and nothing
  /// else: a path, userinfo, query or fragment can carry a key, and a
  /// failure line is permanent. What does not parse as a URL is written
  /// as a fixed placeholder rather than verbatim.
  static String normalisedEndpoint(String endpoint) {
    final uri = Uri.tryParse(endpoint);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return 'unparseable endpoint';
    }
    return endpointOrigin(uri);
  }

  /// [base] plus `text`, cut on a rune boundary until the whole payload
  /// encodes within [maxRecordedTextBytes]; a cut adds `truncated` with
  /// the original byte length. With [omitEmpty], an empty text is left
  /// out (a failure with no partial output). Measured after encoding, so
  /// escape-heavy text cannot push the line past the archive's cap.
  static Map<String, Object?> _fitted(
    Map<String, Object?> base,
    String text, {
    bool omitEmpty = false,
  }) {
    final original = utf8.encode(text).length;
    var candidate = text;
    while (true) {
      final payload = {
        ...base,
        if (candidate.isNotEmpty || !omitEmpty) 'text': candidate,
        if (candidate.length != text.length) 'truncated': original,
      };
      final encoded = utf8.encode(jsonEncode(payload)).length;
      if (encoded <= maxRecordedTextBytes || candidate.isEmpty) return payload;
      // Shrink in proportion to the overshoot, and always by something.
      final have = utf8.encode(candidate).length;
      final target = (have * maxRecordedTextBytes / encoded).floor() - 64;
      candidate = _clipBytes(candidate, target < have ? target : have - 1);
    }
  }

  /// Cuts [text] to at most [bytes] of UTF-8 on a rune boundary.
  static String _clipBytes(String text, int bytes) {
    if (utf8.encode(text).length <= bytes) return text;
    final out = StringBuffer();
    var used = 0;
    for (final rune in text.runes) {
      final width = rune < 0x80
          ? 1
          : rune < 0x800
          ? 2
          : rune < 0x10000
          ? 3
          : 4;
      if (used + width > bytes) break;
      out.writeCharCode(rune);
      used += width;
    }
    return out.toString();
  }
}

/// A call as seen through the recorder: the same deltas, re-broadcast,
/// plus the archive ids as they are written.
final class RecordedCall {
  RecordedCall._(
    this.request,
    this._call, {
    required this.decision,
    required this.fallback,
    required this.contextHash,
    required this.taskContextWithheld,
  });

  final LlmCall _call;
  final _deltas = StreamController<LlmDelta>.broadcast();
  final _done = Completer<LlmResult>();
  final _text = StringBuffer();
  final _reasoning = StringBuffer();

  /// Id of the `provider.request` line — known before the first delta.
  final BlobRef request;

  /// Id of the `policy.decision` line; null for a local provider, which
  /// has none.
  final BlobRef? decision;

  /// Id of the `policy.fallback` line (#62); null when the first choice
  /// answered, or when the caller named the provider itself.
  final BlobRef? fallback;

  /// The `context_hash` on the request line: the blobref of the messages
  /// as sent, policy applied (ADR 0011).
  final BlobRef contextHash;

  /// Whether the policy dropped the request's task context: the
  /// assistant is answering without the list.
  final bool taskContextWithheld;

  BlobRef? _response;
  BlobRef? _failure;
  BlobRef? _usage;

  /// Id of the `provider.response` line; set once [done] completes, null
  /// when the call failed.
  BlobRef? get response => _response;

  /// Id of the `provider.failure` line; set once [done] completes, null
  /// unless the call failed.
  BlobRef? get failure => _failure;

  /// Id of the `provider.usage` line; set once [done] completes.
  BlobRef? get usage => _usage;

  /// Broadcast: the recorder is the real subscriber, so a client that
  /// never listens still gets a full record.
  Stream<LlmDelta> get deltas => _deltas.stream;

  /// What has arrived so far — for a listener that attaches late.
  String get text => _text.toString();

  /// The reasoning so far, kept apart from [text].
  String get reasoning => _reasoning.toString();

  /// Completes after the archive writes, so a caller that awaits this can
  /// read the log immediately. Never completes with an error: an archive
  /// that refuses a line makes the result a failure of kind
  /// [LlmFailureKind.archive], with [archiveError] holding the cause.
  Future<LlmResult> get done => _done.future;

  Object? _archiveError;

  /// What the archive threw, when it refused to record this call.
  Object? get archiveError => _archiveError;

  void cancel() => _call.cancel();

  void _add(LlmDelta delta) {
    (delta.reasoning ? _reasoning : _text).write(delta.text);
    _deltas.add(delta);
  }

  void _finish(LlmResult result) {
    _done.complete(result);
    _deltas.close();
  }
}

/// The call the recorder substitutes when a provider throws from `start`.
final class _FailedCall implements LlmCall {
  _FailedCall(this._result);

  final LlmResult _result;

  @override
  Stream<LlmDelta> get deltas => const Stream.empty();

  @override
  Future<LlmResult> get done => Future.value(_result);

  @override
  void cancel() {}
}
