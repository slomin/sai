import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../archive/event.dart';
import '../../secrets/secret_store.dart';
import '../../settings/endpoint.dart';
import '../call.dart';
import '../effort.dart';
import '../failure.dart';
import '../openai_compatible/dialect.dart';
import '../openai_compatible/policy.dart';
import '../openai_compatible/sse.dart';
import '../openai_compatible/transport.dart';
import '../probe.dart';
import '../provider.dart';
import 'events.dart';
import 'openai.dart';
import 'request.dart';

/// OpenAI's Responses API (#26) over the one bounded transport (ADR
/// 0009): `POST /v1/responses` on the fixed origin, the key read from the
/// Keychain at call time and sent as one header, streamed, stored
/// nowhere, no tools, no conversation state. Not chat completions and
/// not an `openai_compatible` endpoint: the body, the stream and the
/// refusals are the Responses API's own ([responsesBody],
/// [ResponsesEvent]). A request that began is never retried: an
/// unsupported model/effort pair fails once, in fixed words, with the
/// request left as it was — no retry without the effort, no other
/// model, no other billing.
final class OpenAiResponsesProvider
    implements LlmProvider, LlmEndpointProbe, ConfiguredEffort {
  OpenAiResponsesProvider({
    required this.id,
    required this.defaultModel,
    required this.secrets,
    required this.credential,
    this.reasoningEffort,
    Uri? endpoint,
    this.deadlines = const OpenAiDeadlines(),
    HttpClient Function()? clientFactory,
  }) : _endpoint = _fixedOrigin(endpoint),
       origin = endpointOrigin(_fixedOrigin(endpoint)),
       _http = BoundedHttp(
         origin: endpointOrigin(_fixedOrigin(endpoint)),
         deadlines: deadlines,
         clientFactory: clientFactory,
       );

  /// The endpoint a test may hand in for the fixed one: a loopback stub
  /// and nothing else, so no override can point the key at another host.
  static Uri _fixedOrigin(Uri? endpoint) {
    if (endpoint == null || endpoint == openAiEndpoint) return openAiEndpoint;
    if (!isLoopbackHost(endpoint.host)) {
      throw ArgumentError(
        'the OpenAI origin moves only to a loopback stub in tests',
      );
    }
    return endpoint;
  }

  @override
  final String id;

  /// The exact model id every request names unless it asks for another.
  @override
  final String defaultModel;

  /// The entry's own effort (#26): null is Model default, and no
  /// `reasoning` goes on the wire; a word goes exactly as stored.
  @override
  final ReasoningEffort? reasoningEffort;

  /// Secret-store account of the key — always named for this kind.
  final String credential;

  /// `scheme://host[:port]` — what failures name.
  final String origin;

  final OpenAiDeadlines deadlines;
  final Uri _endpoint;

  /// Read at call time, never held onto beyond the header it yields.
  final SecretStore secrets;
  final BoundedHttp _http;
  final _running = <LlmCallController>{};

  /// Billed to an API project, on OpenAI's servers: cloud, always.
  @override
  LlmPrivacy get privacy => LlmPrivacy.cloud;

  @override
  String get displayName => '$id @ $origin';

  /// The settings `kind` a configuration of this provider carries.
  String get kind => openAiKind;

  /// Whether this provider takes a key: always, for this kind.
  bool get takesKey => true;

  /// The `/v1` base this provider talks to.
  Uri get endpoint => _endpoint;

  Uri get _responses => _endpoint.replace(path: '${_endpoint.path}/responses');

  /// The most a refused response's body is read for its `error.param`
  /// and `error.code`: enough for any error object, never a document.
  static const maxRefusalBytes = 64 << 10;

  @override
  LlmCall start(LlmRequest request) {
    final model = ModelRef(provider: id, id: request.model ?? defaultModel);
    final attempt = TransportAttempt();
    final controller = LlmCallController(model: model, onCancel: attempt.abort);
    _running.add(controller);
    controller.call.done.whenComplete(() => _running.remove(controller));
    final client = _http.client;
    controller.run(() => _run(controller, attempt, request, client));
    return controller.call;
  }

  /// The checks before a socket opens: closed, then the key read now and
  /// never kept. The origin never moves, so there is no binding to check.
  (LlmFailure?, String?) _prepare() {
    if (_http.isClosed) {
      return (
        LlmFailure(
          LlmFailureKind.internal,
          TransportText.closed,
          endpoint: origin,
        ),
        null,
      );
    }
    return readBearer(secrets, credential, origin: origin);
  }

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

    final body = jsonEncode(
      responsesBody(request, model: request.model ?? defaultModel),
    );
    final (sendFailure, sent) = await _http.post(
      client,
      _responses,
      headers: const {},
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
        _http.refuse(
          LlmFailureKind.rejected,
          TransportText.redirected,
          status: status,
        ),
      );
    }
    if (status < 200 || status >= 300) {
      // Refused. The body says which field OpenAI objected to — and only
      // that is read: `error.param` and `error.code`, never the message,
      // which quotes the request. Nothing is re-sent: the effort, the
      // schema and the model stand as the person chose them.
      final text = await _http.readCapped(response, maxRefusalBytes);
      Object? json;
      if (text != null) {
        try {
          json = jsonDecode(text);
        } on FormatException {
          json = null;
        }
      }
      return fail(
        _refusal(status, json, schema: request.responseSchema != null),
      );
    }
    final type = response.headers.contentType?.mimeType;
    if (type != 'text/event-stream') {
      _http.drain(response);
      return fail(
        _http.refuse(LlmFailureKind.protocol, TransportText.notAStream),
      );
    }

    ResponsesEvent? terminal;
    LlmFailure? failure;
    final ended = Completer<void>();
    void end() {
      if (!ended.isCompleted) ended.complete();
    }

    late final StreamSubscription<SseEvent> sub;
    void stop(LlmFailure? why) {
      failure = why;
      quietly(sub.cancel());
      end();
    }

    sub = _http
        .events(
          response,
          first: deadlines.firstTokenFor(utf8.encode(body).length),
          between: deadlines.interToken,
        )
        .listen(
          (event) {
            if (event.comment) return;
            final ResponsesEvent parsed;
            try {
              parsed = ResponsesEvent.parse(event.data);
            } on FormatException {
              return stop(
                _http.refuse(LlmFailureKind.protocol, TransportText.badChunk),
              );
            }
            switch (parsed.kind) {
              case ResponsesEventKind.text:
                final text = parsed.delta;
                if (text != null && text.isNotEmpty) controller.add(text);
              case ResponsesEventKind.reasoning:
                final thought = parsed.delta;
                if (thought != null && thought.isNotEmpty) {
                  controller.addReasoning(thought);
                }
              case ResponsesEventKind.completed:
              case ResponsesEventKind.incomplete:
                terminal = parsed;
                if (parsed.usage != null) controller.usage = parsed.usage;
                stop(null);
              case ResponsesEventKind.failed:
                stop(
                  _http.refuse(
                    LlmFailureKind.rejected,
                    TransportText.errorPayload,
                  ),
                );
              case ResponsesEventKind.unexpectedItem:
                // sai sent no tools; a model reaching for one is refused,
                // and the stream cut before it goes further.
                stop(
                  _http.refuse(
                    LlmFailureKind.protocol,
                    TransportText.toolCalled,
                  ),
                );
              case ResponsesEventKind.refused:
                // The model declined to answer. Its words about that are
                // not kept; nothing is re-sent.
                stop(
                  _http.refuse(LlmFailureKind.rejected, TransportText.refused),
                );
              case ResponsesEventKind.other:
                break;
            }
          },
          onError: (Object error) {
            stop(
              error is TimeoutException
                  ? _http.refuse(LlmFailureKind.timeout, TransportText.stalled)
                  : _http.refuse(
                      LlmFailureKind.protocol,
                      TransportText.endedEarly,
                    ),
            );
          },
          onDone: end,
          cancelOnError: true,
        );
    attempt.subscription = sub;
    await ended.future;
    if (controller.isDone) return;
    if (failure != null) return fail(failure!);
    final done = terminal;
    if (done == null) {
      return fail(
        _http.refuse(LlmFailureKind.protocol, TransportText.endedEarly),
      );
    }
    if (done.kind == ResponsesEventKind.incomplete &&
        done.incompleteReason != 'max_output_tokens') {
      // Stopped short for a reason that is not the cap sai set — a
      // filter, say. What came is kept with the failure; nothing is
      // re-sent.
      return fail(
        _http.refuse(LlmFailureKind.rejected, TransportText.errorPayload),
      );
    }
    controller.finish(
      LlmResult(
        text: controller.text,
        reasoning: controller.reasoning,
        finish: done.kind == ResponsesEventKind.incomplete
            ? LlmFinish.length
            : LlmFinish.stop,
        // Lineage is the exact id asked for; the dated snapshot upstream
        // says answered rides as the version, the response's own id as
        // the request id — never a guessed alias in either place.
        model: ModelRef(
          provider: id,
          id: controller.model.id,
          version: done.model,
          requestId: done.responseId,
        ),
        usage: done.usage,
      ),
    );
  }

  /// What a refused response means, from its status and the error
  /// object's `param`/`code` alone (#26): the model is not this key's,
  /// the model does not take the effort, the schema was refused, the
  /// project has no credit — else the common words for the status.
  LlmFailure _refusal(int status, Object? json, {required bool schema}) {
    final error = json is Map<String, Object?> ? json['error'] : null;
    final param = error is Map<String, Object?> && error['param'] is String
        ? error['param'] as String
        : '';
    final code = error is Map<String, Object?> && error['code'] is String
        ? error['code'] as String
        : '';
    String? text;
    if (code == 'model_not_found' || param == 'model') {
      text = TransportText.noSuchModel;
    } else if (status == 400 && param.startsWith('reasoning')) {
      text = TransportText.effortRefused;
    } else if (status == 400 && schema && param.startsWith('text')) {
      text = TransportText.schemaRefused;
    } else if (status == 429 && code == 'insufficient_quota') {
      text = TransportText.noCredit;
    }
    if (text == null) return statusFailure(status, origin);
    return _http.refuse(LlmFailureKind.rejected, text, status: status);
  }

  /// The key checked and `GET /v1/models` read: `ok` with the ids the
  /// key can reach, no context window (a cloud provider's budget stays
  /// the conservative one) — or the failure. api.openai.com has no
  /// keyless health path, so without a key the probe fails `credential`
  /// before a socket, as every call would.
  @override
  Future<EndpointInfo> probe() async {
    final answer = await fetch('/models');
    if (answer.failure != null) {
      return EndpointInfo(
        health: EndpointHealth.unavailable,
        failure: answer.failure,
      );
    }
    final ids = openAiModelIds(answer.json);
    if (ids == null) {
      return EndpointInfo(
        health: EndpointHealth.unavailable,
        failure: _http.refuse(LlmFailureKind.protocol, TransportText.notModels),
      );
    }
    return EndpointInfo(
      health: EndpointHealth.ok,
      models: ids,
      serverKind: openAiKind,
    );
  }

  /// One bounded GET of [path] under `/v1`, on the prepared path (closed
  /// guard, the key read now, no redirects, the deadlines), with a body
  /// cap of the caller's. Discovery, not a call: nothing reaches the
  /// archive or the usage totals.
  Future<DiscoveryAnswer> fetch(
    String path, {
    int maxBytes = BoundedHttp.maxProbeBytes,
  }) async {
    final (refused, auth) = _prepare();
    if (refused != null) return DiscoveryAnswer(0, failure: refused);
    return _http.get(
      _http.client,
      _endpoint.replace(path: '${_endpoint.path}$path'),
      headers: const {},
      auth: auth,
      maxBytes: maxBytes,
    );
  }

  /// Whether [close] has been called.
  bool get isClosed => _http.isClosed;

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
