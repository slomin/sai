import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../archive/event.dart';
import '../../secrets/secret_store.dart';
import '../../settings/endpoint.dart';
import '../call.dart';
import '../failure.dart';
import '../probe.dart';
import '../provider.dart';
import 'chunks.dart';
import 'dialect.dart';
import 'policy.dart';
import 'sse.dart';
import 'transport.dart';

/// An OpenAI-compatible `/v1` backend — llama.cpp's `llama-server`, LM
/// Studio, the LAN box — over the one direct, bounded transport
/// ([BoundedHttp], ADR 0009): no redirects, no proxy, no certificate
/// bypass, plaintext only to this machine or the LAN (ADR 0012), the key
/// sent only to the origin it was entered for, and a deadline on every
/// stage. Failures carry fixed text and the origin. What a backend wants
/// beyond that — its headers, body fields, the way reasoning is switched
/// off, how it is asked about itself — is its [dialect] (#24); the
/// chat-completions shape is this class's.
///
/// The key is read from [secrets] at call time, never held.
final class OpenAiCompatibleProvider implements LlmProvider, LlmEndpointProbe {
  OpenAiCompatibleProvider({
    required this.id,
    required Uri endpoint,
    required this.defaultModel,
    required this._secrets,
    this.credential,
    this.credentialOrigin,
    this.privacy = LlmPrivacy.local,
    this.deadlines = const OpenAiDeadlines(),
    this.dialect = const LocalDialect(),
    HttpClient Function()? clientFactory,
  }) : _endpoint = _trimSlash(endpoint),
       origin = endpointOrigin(endpoint),
       _http = BoundedHttp(
         origin: endpointOrigin(endpoint),
         deadlines: deadlines,
         clientFactory: clientFactory,
       );

  static Uri _trimSlash(Uri uri) => uri.path.endsWith('/')
      ? uri.replace(path: uri.path.substring(0, uri.path.length - 1))
      : uri;

  @override
  final String id;

  /// What this backend wants beyond the common transport.
  final OpenAiDialect dialect;

  /// The settings `kind` a configuration of this provider would carry.
  String get kind => dialect.kind;

  @override
  String get displayName => '$id @ $origin';

  /// Where the inference happens, as the configuration says or the
  /// endpoint's host suggests (`openAiCompatibleFactory`); the privacy
  /// policy (#27) reads this. The transport itself has no opinion.
  @override
  final LlmPrivacy privacy;

  /// The model used when a request names none. [loadedModel] stands for
  /// whatever the endpoint has loaded.
  @override
  final String defaultModel;

  /// A [defaultModel] that names no model: nothing goes on the wire as
  /// `model` (LM Studio answers with the model it has loaded, `llama-server`
  /// has one model anyway), and the response's lineage carries the id the
  /// stream reports.
  static const loadedModel = 'loaded model';

  /// The id that goes on the wire for [request], or null for [loadedModel].
  String? _wireModel(LlmRequest request) {
    final model = request.model ?? defaultModel;
    return model == loadedModel ? null : model;
  }

  /// `scheme://host[:port]` of the endpoint — what failures name.
  final String origin;

  /// Secret-store account of the key, null for a keyless endpoint.
  final String? credential;

  /// The origin the key was entered for (`ProviderConfig.credentialOrigin`).
  /// Live: the registry updates it when a key is stored, so a running
  /// call is never cut for it.
  String? credentialOrigin;

  final OpenAiDeadlines deadlines;

  final Uri _endpoint;

  /// The `/v1` base this provider talks to.
  Uri get endpoint => _endpoint;

  /// Whether this provider takes a key, as its configuration would say.
  bool get takesKey => credential != null;

  final SecretStore _secrets;
  final BoundedHttp _http;
  final _running = <LlmCallController>{};

  Uri get _chat =>
      _endpoint.replace(path: '${_endpoint.path}/chat/completions');

  @override
  LlmCall start(LlmRequest request) {
    final model = ModelRef(provider: id, id: request.model ?? defaultModel);
    final attempt = TransportAttempt();
    final controller = LlmCallController(model: model, onCancel: attempt.abort);
    _running.add(controller);
    controller.call.done.whenComplete(() => _running.remove(controller));
    // The client is captured here: the whole call — the 400-ladder
    // retry included — stays on the client it started with, so a
    // releaseIdle between its requests cannot route one onto the
    // replacement and leak a fresh socket to a switched-away endpoint.
    final client = _http.client;
    controller.run(() => _run(controller, attempt, request, client));
    return controller.call;
  }

  /// The checks every request passes before a socket is opened: the
  /// failure that stops it, or the `Authorization` value to send (null
  /// for a keyless endpoint).
  (LlmFailure?, String?) _prepare() {
    LlmFailure refuse(LlmFailureKind kind, String text) =>
        LlmFailure(kind, text, endpoint: origin);
    if (_http.isClosed) {
      return (refuse(LlmFailureKind.internal, TransportText.closed), null);
    }
    if (_endpoint.scheme == 'http' && !isPrivateHost(_endpoint.host)) {
      return (
        refuse(LlmFailureKind.unreachable, TransportText.plaintext),
        null,
      );
    }
    final account = credential;
    if (account == null) return (null, null);
    // The key is read now and never kept (ADR 0008); the dev flavor's
    // own words, a Keychain that could not be read and no key stored are
    // the transport's fixed failures.
    final (refused, auth) = readBearer(_secrets, account, origin: origin);
    if (refused != null) return (refused, null);
    if (dialect.bindsKeyToOrigin && credentialOrigin != origin) {
      return (
        refuse(LlmFailureKind.credential, TransportText.keyElsewhere),
        null,
      );
    }
    return (null, auth);
  }

  /// Whether this endpoint answered 400 to `reasoning_effort`, and to
  /// `chat_template_kwargs`, once; from then on that switch is not sent
  /// to it. Negotiated one at a time: the template switch (llama.cpp's)
  /// is dropped first, OpenAI's word second, so an endpoint that knows
  /// either still gets the one it knows. Only a dialect that negotiates
  /// (the local one) sends either; another says it its own way, once.
  var _reasoningRefused = false;
  var _templateSwitchRefused = false;

  Future<void> _run(
    LlmCallController controller,
    TransportAttempt attempt,
    LlmRequest request,
    HttpClient client,
  ) async {
    void fail(LlmFailure failure) {
      if (controller.isDone) return;
      controller.finish(
        LlmResult(
          text: controller.text,
          finish: LlmFinish.failed,
          model: controller.model,
          usage: controller.usage,
          failure: failure,
          reasoning: controller.reasoning,
        ),
      );
    }

    final (refused, auth) = _prepare();
    if (refused != null) return fail(refused);

    final wireModel = _wireModel(request);
    final off = request.reasoningEffort == ReasoningEffort.none;
    final negotiate = off && dialect.negotiatesReasoning;
    final sendEffort = negotiate && !_reasoningRefused;
    final sendTemplateSwitch = negotiate && !_templateSwitchRefused;
    final body = jsonEncode({
      'model': ?wireModel,
      'messages': [
        for (final m in request.messages)
          {'role': m.role.name, 'content': m.text},
      ],
      'stream': true,
      ...dialect.fields(request, reasoningOff: off),
      if (request.maxTokens != null) 'max_tokens': request.maxTokens,
      if (request.temperature != null) 'temperature': request.temperature,
      // Off, said both ways: OpenAI's word (LM Studio, and llama.cpp on
      // master) and the template switch llama-server actually reads on
      // the LAN box (#23) — measured: reasoning_effort alone leaves
      // Qwen3.8 thinking there.
      if (sendEffort) 'reasoning_effort': 'none',
      if (sendTemplateSwitch)
        'chat_template_kwargs': {'enable_thinking': false},
      // A schema-constrained answer (#35); the OpenAI nesting both
      // llama-server and LM Studio read.
      if (request.responseSchema case final schema?)
        'response_format': schema.toWire(),
    });

    final (sendFailure, sent) = await _http.post(
      client,
      _chat,
      headers: dialect.headers,
      auth: auth,
      body: body,
      attempt: attempt,
      abandoned: () => controller.isDone,
    );
    if (sendFailure != null) return fail(sendFailure);
    if (sent == null) return;
    final response = sent;
    if (controller.isDone) return _http.drain(response);

    final status = response.statusCode;
    if (status >= 300 && status < 400) {
      _http.drain(response);
      return fail(
        LlmFailure(
          LlmFailureKind.rejected,
          TransportText.redirected,
          endpoint: origin,
          status: status,
        ),
      );
    }
    if (status == 400 && (sendTemplateSwitch || sendEffort)) {
      // An endpoint that does not know a switch answers 400; drop one,
      // ask again and remember, so the next call goes straight through.
      // The caller's wish is on the request line either way; what the
      // backend understood is its own affair.
      if (sendTemplateSwitch) {
        _templateSwitchRefused = true;
      } else {
        _reasoningRefused = true;
      }
      _http.drain(response);
      return _run(controller, attempt, request, client);
    }
    if (status == 400 && request.responseSchema != null) {
      // The backend refused the response schema. A proposal without its
      // grammar would be unvalidated output, so there is no retry
      // without it (#35).
      _http.drain(response);
      return fail(
        LlmFailure(
          LlmFailureKind.rejected,
          TransportText.schemaRefused,
          endpoint: origin,
          status: status,
        ),
      );
    }
    if (status < 200 || status >= 300) {
      _http.drain(response);
      return fail(_refused(status));
    }
    final type = response.headers.contentType?.mimeType;
    if (type != 'text/event-stream') {
      _http.drain(response);
      return fail(
        LlmFailure(
          LlmFailureKind.protocol,
          TransportText.notAStream,
          endpoint: origin,
        ),
      );
    }

    String? finish;
    String? requestId;
    LlmUsage? usage;
    double? tokensPerSecond;
    var doneSeen = false;
    LlmFailure? failure;
    final ended = Completer<void>();
    void end() {
      if (!ended.isCompleted) ended.complete();
    }

    LlmUsage merged() => LlmUsage(
      promptTokens: usage?.promptTokens,
      completionTokens: usage?.completionTokens,
      totalTokens: usage?.totalTokens,
      tokensPerSecond: tokensPerSecond,
      cost: usage?.cost,
    );

    late final StreamSubscription<SseEvent> sub;
    sub = _http
        .events(
          response,
          // Scaled to the prompt: ingestion of a whole-catalog turn
          // legitimately takes minutes (#105).
          first: deadlines.firstTokenFor(utf8.encode(body).length),
          between: deadlines.interToken,
        )
        .listen(
          (event) {
            if (event.comment) return;
            if (event.isDone) {
              doneSeen = true;
              quietly(sub.cancel());
              end();
              return;
            }
            final ChatChunk chunk;
            try {
              chunk = ChatChunk.parse(event.data);
            } on FormatException {
              failure = LlmFailure(
                LlmFailureKind.protocol,
                TransportText.badChunk,
                endpoint: origin,
              );
              quietly(sub.cancel());
              end();
              return;
            }
            if (chunk.error) {
              failure = LlmFailure(
                LlmFailureKind.rejected,
                TransportText.errorPayload,
                endpoint: origin,
              );
              quietly(sub.cancel());
              end();
              return;
            }
            requestId ??= chunk.id;
            // Nothing was asked for: the backend's word is the lineage,
            // from the first chunk on — a cancel carries it too.
            if (controller.model.id == loadedModel && chunk.model != null) {
              controller.model = ModelRef(provider: id, id: chunk.model!);
            }
            if (chunk.usage != null) usage = chunk.usage;
            if (chunk.tokensPerSecond != null) {
              tokensPerSecond = chunk.tokensPerSecond;
            }
            if (chunk.usage != null || chunk.tokensPerSecond != null) {
              controller.usage = merged();
            }
            if (chunk.finishReason != null) finish = chunk.finishReason;
            final thought = chunk.reasoning;
            if (thought != null && thought.isNotEmpty) {
              controller.addReasoning(thought);
            }
            final text = chunk.content;
            if (text != null && text.isNotEmpty) controller.add(text);
          },
          onError: (Object error) {
            failure = error is TimeoutException
                ? LlmFailure(
                    LlmFailureKind.timeout,
                    TransportText.stalled,
                    endpoint: origin,
                  )
                : LlmFailure(
                    LlmFailureKind.protocol,
                    TransportText.endedEarly,
                    endpoint: origin,
                  );
            quietly(sub.cancel());
            end();
          },
          onDone: end,
          cancelOnError: true,
        );
    attempt.subscription = sub;
    await ended.future;
    if (controller.isDone) return;
    if (failure != null) return fail(failure!);
    if (!doneSeen && finish == null) {
      return fail(
        LlmFailure(
          LlmFailureKind.protocol,
          TransportText.endedEarly,
          endpoint: origin,
        ),
      );
    }
    controller.finish(
      LlmResult(
        text: controller.text,
        reasoning: controller.reasoning,
        finish: finish == 'length' ? LlmFinish.length : LlmFinish.stop,
        // Lineage is what was asked for; the request id is the backend's.
        model: ModelRef(
          provider: id,
          id: controller.model.id,
          requestId: requestId,
        ),
        usage: usage == null && tokensPerSecond == null ? null : merged(),
      ),
    );
  }

  /// A non-2xx answer as a failure: the dialect's own word for the
  /// status when it has one, the common ladder otherwise.
  LlmFailure _refused(int status) => switch (dialect.refusal(status)) {
    final text? => LlmFailure(
      LlmFailureKind.rejected,
      text,
      endpoint: origin,
      status: status,
    ),
    null => statusFailure(status, origin),
  };

  @override
  Future<EndpointInfo> probe() async {
    final (refused, auth) = _prepare();
    if (refused != null) {
      return EndpointInfo(health: EndpointHealth.unavailable, failure: refused);
    }
    // Bound to the client generation it started on: a probe overtaken
    // by releaseIdle fails its remaining requests on the retired client
    // — whose soft close refuses new work — rather than opening fresh
    // sockets to the switched-away endpoint. Its answer is stale by
    // then anyway; the connection watcher drops it by epoch.
    final client = _http.client;
    return dialect.probe(
      Discovery(
        get: (uri) =>
            _http.get(client, uri, headers: dialect.headers, auth: auth),
        base: _endpoint,
        origin: origin,
        wantsLoadedModel: defaultModel == loadedModel,
        defaultModel: defaultModel,
      ),
    );
  }

  /// One bounded GET of [path] under the endpoint, on demand (#112): the
  /// same prepared path as a probe — closed and plaintext guards, the
  /// key read now, the dialect's headers, no redirects, the deadlines —
  /// with a body cap of the caller's, since a catalogue is bigger than
  /// a probe answer. A refusal comes back as an answer with a failure and
  /// no request made. Nothing here reaches the archive or the usage
  /// totals: discovery is not an inference call.
  Future<DiscoveryAnswer> fetch(
    String path, {
    int maxBytes = maxProbeBytes,
  }) async {
    final (refused, auth) = _prepare();
    if (refused != null) return DiscoveryAnswer(0, failure: refused);
    return _http.get(
      _http.client,
      _endpoint.replace(path: '${_endpoint.path}$path'),
      headers: dialect.headers,
      auth: auth,
      maxBytes: maxBytes,
    );
  }

  /// The most a discovery answer may be; a model list is kilobytes.
  static const maxProbeBytes = BoundedHttp.maxProbeBytes;

  /// Whether [close] has been called.
  bool get isClosed => _http.isClosed;

  /// Retires the current client so its idle keep-alive sockets close
  /// now; a fresh client serves the next call. Requests already running
  /// (an aborting warm, a probe) finish on the old client, which tears
  /// itself down when the last of them ends (#109).
  @override
  void releaseIdle() => _http.releaseIdle();

  @override
  Future<void> close() async {
    for (final controller in _running.toList()) {
      controller.cancel();
    }
    _http.close();
  }
}
