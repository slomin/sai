import 'dart:async';
import 'dart:convert';

import '../archive/archive.dart';
import '../archive/blobref.dart';
import '../archive/event.dart';
import 'call.dart';
import 'failure.dart';
import 'provider.dart';

/// The most text one recorded line carries. Half the archive's line cap,
/// leaving room for the envelope and the rest of the payload.
const maxRecordedTextBytes = 512 << 10;

/// The single write path for provider traffic: every call through here
/// lands in the archive as a request line, a response or failure line,
/// and a usage line — before [RecordedCall.done] completes. See the
/// "Provider traffic" section of `docs/archive/event-log-v0.md`.
///
/// The provider is passed per call, not held, so switching the active
/// provider can never disturb a call already running.
final class LlmRecorder {
  LlmRecorder({
    required this.archive,
    required this.source,
    required this.clock,
  });

  final Archive archive;

  /// The `source` written on every line, e.g. [EventSources.app].
  final String source;
  final DateTime Function() clock;

  /// Appends `provider.request`, then starts [provider]. Returns once the
  /// request line is in the archive — a crash after that still leaves
  /// the request on record.
  ///
  /// Throws [ArgumentError], before the provider is touched, when the
  /// request is too large to record: what cannot be recorded is not sent.
  Future<RecordedCall> start(LlmProvider provider, LlmRequest request) async {
    final payload = _requestPayload(request);
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
    final stored = await archive.append(
      EventDraft(
        type: EventTypes.providerRequest,
        actor: Actor.system,
        source: source,
        payload: payload,
        model: target,
      ),
    );
    LlmCall call;
    try {
      call = provider.start(request);
    } catch (error) {
      call = _FailedCall(
        LlmResult(
          text: '',
          finish: LlmFinish.failed,
          model: target,
          failure: LlmFailure(
            LlmFailureKind.internal,
            'provider.start threw: $error',
          ),
        ),
      );
    }
    final recorded = RecordedCall._(stored.id, call);
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
        finish: LlmFinish.failed,
        model: result.model,
        usage: result.usage,
        failure: LlmFailure(
          LlmFailureKind.internal,
          'provider deltas stream errored: $streamError',
        ),
      );
    }
    final ended = clock();
    final durationMs = ended.difference(started).inMilliseconds;
    try {
      final failure = result.failure;
      if (result.finish == LlmFinish.failed && failure != null) {
        final (text, truncated) = _clip(result.text);
        final stored = await archive.append(
          EventDraft(
            type: EventTypes.providerFailure,
            actor: Actor.system,
            source: source,
            payload: {
              ...failure.toJson(),
              if (text.isNotEmpty) 'text': text,
              'truncated': ?truncated,
            },
            model: result.model,
            refs: [recorded.request],
          ),
        );
        recorded._failure = stored.id;
      } else {
        final (text, truncated) = _clip(result.text);
        final stored = await archive.append(
          EventDraft(
            type: EventTypes.providerResponse,
            actor: Actor.assistant,
            source: source,
            payload: {
              'text': text,
              'finish': result.finish.name,
              'truncated': ?truncated,
            },
            model: result.model,
            refs: [recorded.request],
          ),
        );
        recorded._response = stored.id;
      }
    } catch (error, stack) {
      await _usage(recorded, result, durationMs, swallow: true);
      recorded._finish(error: error, stack: stack);
      return;
    }
    try {
      await _usage(recorded, result, durationMs);
    } catch (error, stack) {
      recorded._finish(error: error, stack: stack);
      return;
    }
    recorded._finish(result: result);
  }

  Future<void> _usage(
    RecordedCall recorded,
    LlmResult result,
    int durationMs, {
    bool swallow = false,
  }) async {
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
    } catch (_) {
      if (!swallow) rethrow;
    }
  }

  static Map<String, Object?> _requestPayload(LlmRequest request) => {
    'messages': [for (final m in request.messages) m.toJson()],
    if (request.maxTokens != null) 'max_tokens': request.maxTokens,
    if (request.temperature != null) 'temperature': request.temperature,
  };

  /// Cuts [text] to [maxRecordedTextBytes] of UTF-8 on a rune boundary.
  /// Returns the text to record and, when cut, the original byte length.
  static (String, int?) _clip(String text) {
    final bytes = utf8.encode(text).length;
    if (bytes <= maxRecordedTextBytes) return (text, null);
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
      if (used + width > maxRecordedTextBytes) break;
      out.writeCharCode(rune);
      used += width;
    }
    return (out.toString(), bytes);
  }
}

/// A call as seen through the recorder: the same deltas, re-broadcast,
/// plus the archive ids as they are written.
final class RecordedCall {
  RecordedCall._(this.request, this._call);

  final LlmCall _call;
  final _deltas = StreamController<LlmDelta>.broadcast();
  final _done = Completer<LlmResult>();
  final _text = StringBuffer();

  /// Id of the `provider.request` line — known before the first delta.
  final BlobRef request;

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

  /// Completes after the archive writes, so a caller that awaits this can
  /// read the log immediately. Completes with an error only when the
  /// archive refused a line — always await it.
  Future<LlmResult> get done => _done.future;

  void cancel() => _call.cancel();

  void _add(LlmDelta delta) {
    _text.write(delta.text);
    _deltas.add(delta);
  }

  void _finish({LlmResult? result, Object? error, StackTrace? stack}) {
    if (error != null) {
      _done.completeError(error, stack);
    } else {
      _done.complete(result);
    }
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
