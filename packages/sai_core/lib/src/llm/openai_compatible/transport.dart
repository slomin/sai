import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../secrets/secret_store.dart';
import '../failure.dart';
import 'dialect.dart';
import 'policy.dart';
import 'sse.dart';

/// The one transport every outbound provider request goes through (ADR
/// 0009): direct connections, no redirects, no certificate bypass, a
/// deadline on every stage, capped bodies, and failures in fixed words
/// naming only the origin. What a backend wants on top — its path, its
/// body, how its stream reads — is a dialect's business
/// (`openai_compatible/`, `openai/`); the socket rules are one and live
/// here. The key is never held: a caller reads it with [readBearer] at
/// call time and hands the header value over per request.
///
/// A client generation is captured by each call: [releaseIdle] retires
/// the current client so its idle keep-alive sockets close now and a
/// fresh one serves the next call, while requests already running finish
/// on the old one (#109).
final class BoundedHttp {
  BoundedHttp({
    required this.origin,
    this.deadlines = const OpenAiDeadlines(),
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new {
    _client = _newClient();
  }

  /// `scheme://host[:port]` — all a failure ever says about where.
  final String origin;

  final OpenAiDeadlines deadlines;
  final HttpClient Function() _clientFactory;
  late HttpClient _client;
  var _closed = false;

  /// A configured transport client. Direct connections only:
  /// `HTTP(S)_PROXY` in the environment would otherwise route a LAN key
  /// through whatever it names.
  HttpClient _newClient() => _clientFactory()
    ..connectionTimeout = deadlines.connect
    ..findProxy = (_) => 'DIRECT';

  /// The current client generation; a call captures it once.
  HttpClient get client => _client;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  LlmFailure refuse(LlmFailureKind kind, String text, {int? status}) =>
      LlmFailure(kind, text, endpoint: origin, status: status);

  /// One POST of a JSON [body] to [uri] with the transport's rules: no
  /// redirects, JSON in, an event stream expected, the dialect's
  /// [headers], the `Authorization` value in the header object alone,
  /// and the first-response deadline. Answers the response, or the
  /// failure that stands for it. [abandoned] is asked once the request
  /// object exists, so a call cancelled meanwhile is aborted before a
  /// byte goes out.
  Future<(LlmFailure?, HttpClientResponse?)> post(
    HttpClient client,
    Uri uri, {
    required Map<String, String> headers,
    required String? auth,
    required String body,
    required TransportAttempt attempt,
    required bool Function() abandoned,
  }) async {
    try {
      final req = await client.postUrl(uri);
      if (abandoned()) {
        req.abort();
        return (null, null);
      }
      attempt.request = req;
      req
        ..followRedirects = false
        ..headers.contentType = ContentType.json
        ..headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      for (final h in headers.entries) {
        req.headers.set(h.key, h.value);
      }
      if (auth != null) req.headers.set(HttpHeaders.authorizationHeader, auth);
      req.add(utf8.encode(body));
      final response = await req.close().timeout(deadlines.firstResponse);
      return (null, response);
    } on TimeoutException {
      attempt.abort();
      return (refuse(LlmFailureKind.timeout, TransportText.noResponse), null);
    } catch (error) {
      if (abandoned()) return (null, null);
      return (connectFailure(error, origin), null);
    }
  }

  /// The events of an SSE [response], a first-token deadline of [first]
  /// then [between] two later events; either fires as a
  /// [TimeoutException] on the stream and ends it. Comments reset both.
  Stream<SseEvent> events(
    HttpClientResponse response, {
    required Duration first,
    required Duration between,
  }) => response.transform(sseEvents()).transform(_deadlines(first, between));

  /// One bounded GET. A non-2xx answer is a failure only for the caller
  /// to judge (a 404 on `/health` just means "not llama.cpp"); its body,
  /// when JSON, comes along for that judgement and is never surfaced.
  Future<DiscoveryAnswer> get(
    HttpClient client,
    Uri uri, {
    required Map<String, String> headers,
    required String? auth,
    int maxBytes = maxProbeBytes,
  }) async {
    HttpClientRequest? req;
    try {
      req = await client.getUrl(uri);
      req.followRedirects = false;
      req.headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
      for (final h in headers.entries) {
        req.headers.set(h.key, h.value);
      }
      if (auth != null) req.headers.set(HttpHeaders.authorizationHeader, auth);
      final response = await req.close().timeout(deadlines.firstResponse);
      final status = response.statusCode;
      if (status >= 300 && status < 400) {
        drain(response);
        return DiscoveryAnswer(
          status,
          failure: refuse(
            LlmFailureKind.rejected,
            TransportText.redirected,
            status: status,
          ),
        );
      }
      final text = await readCapped(response, maxBytes);
      if (text == null) {
        return DiscoveryAnswer(
          status,
          failure: refuse(LlmFailureKind.protocol, TransportText.tooLarge),
        );
      }
      if (status < 200 || status >= 300) {
        Object? json;
        try {
          json = jsonDecode(text);
        } on FormatException {
          json = null;
        }
        // Discovery has no routing to speak of: the common words, not
        // a dialect's chat ones.
        return DiscoveryAnswer(
          status,
          json: json,
          failure: statusFailure(status, origin),
        );
      }
      try {
        return DiscoveryAnswer(status, json: jsonDecode(text));
      } on FormatException {
        return DiscoveryAnswer(
          status,
          failure: refuse(LlmFailureKind.protocol, TransportText.notJson),
        );
      }
    } on TimeoutException {
      req?.abort();
      return DiscoveryAnswer(
        0,
        failure: refuse(LlmFailureKind.timeout, TransportText.noResponse),
      );
    } catch (error) {
      return DiscoveryAnswer(0, failure: connectFailure(error, origin));
    }
  }

  /// The most a discovery answer may be; a model list is kilobytes.
  static const maxProbeBytes = 1 << 20;

  /// The body as text, or null once it passes [maxBytes] — the
  /// subscription is cancelled there, and on the inter-token deadline.
  Future<String?> readCapped(HttpClientResponse response, int maxBytes) async {
    // Chunks kept as they came, one copy at the end: a catalogue is
    // megabytes, and a growable list of bytes would be several of it.
    final bytes = BytesBuilder(copy: false);
    var over = false;
    final done = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    sub = response
        .timeout(deadlines.interToken)
        .listen(
          (chunk) {
            bytes.add(chunk);
            if (bytes.length > maxBytes) {
              over = true;
              quietly(sub.cancel());
              if (!done.isCompleted) done.complete();
            }
          },
          onError: (Object e) {
            quietly(sub.cancel());
            if (!done.isCompleted) done.completeError(e);
          },
          onDone: () {
            if (!done.isCompleted) done.complete();
          },
          cancelOnError: true,
        );
    await done.future;
    return over ? null : utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  /// Lets a response we do not want finish, so the connection is reused
  /// or closed cleanly; errors are of no interest.
  void drain(HttpClientResponse response) {
    unawaited(response.drain<void>().catchError((_) {}));
  }

  /// Retires the current client so its idle keep-alive sockets close
  /// now; a fresh client serves the next call. Requests already running
  /// finish on the old client, which tears itself down when the last of
  /// them ends (#109).
  void releaseIdle() {
    if (_closed) return;
    final old = _client;
    _client = _newClient();
    old.close();
  }

  /// Closes for good: the current client with force, nothing after.
  void close() {
    _closed = true;
    _client.close(force: true);
  }
}

/// A first-token deadline, then a between-events one; either fires as a
/// [TimeoutException] on the stream and ends it. Comments reset both.
StreamTransformer<SseEvent, SseEvent> _deadlines(
  Duration first,
  Duration between,
) => StreamTransformer.fromBind((events) {
  late StreamController<SseEvent> out;
  StreamSubscription<SseEvent>? sub;
  Timer? timer;
  var seen = false;
  void arm() {
    timer?.cancel();
    timer = Timer(seen ? between : first, () {
      out.addError(TimeoutException('stream deadline'));
      out.close();
      sub?.cancel();
    });
  }

  out = StreamController<SseEvent>(
    onListen: () {
      arm();
      sub = events.listen(
        (e) {
          // A keep-alive resets the clock but does not end the wait for
          // the first token: a server may ping while it evaluates.
          if (!e.comment) seen = true;
          arm();
          out.add(e);
        },
        onError: out.addError,
        onDone: () {
          timer?.cancel();
          out.close();
        },
      );
    },
    onCancel: () {
      timer?.cancel();
      return sub?.cancel();
    },
  );
  return out.stream;
});

/// What a running call holds on the wire, so cancel can cut it.
final class TransportAttempt {
  HttpClientRequest? request;
  StreamSubscription<SseEvent>? subscription;

  void abort() {
    request?.abort();
    final sub = subscription;
    if (sub != null) quietly(sub.cancel());
  }
}

/// Cancelling a subscription can hand back the socket's own close error;
/// the call has already been decided by then.
void quietly(Future<void> future) {
  unawaited(future.catchError((_) {}));
}

/// The key under [account] as an `Authorization` value, read now and
/// never kept, or the failure that stops the call before a socket opens:
/// the dev flavor's own words (#95), a Keychain that could not be read,
/// or no key stored. The origin-binding rule is the caller's.
(LlmFailure?, String?) readBearer(
  SecretStore secrets,
  String account, {
  required String origin,
}) {
  final String? key;
  try {
    key = secrets.read(account);
  } on NoSecretsException catch (e) {
    return (
      LlmFailure(LlmFailureKind.credential, e.message, endpoint: origin),
      null,
    );
  } on SecretStoreException {
    return (
      LlmFailure(
        LlmFailureKind.credential,
        TransportText.keychainUnavailable,
        endpoint: origin,
      ),
      null,
    );
  }
  if (key == null) {
    return (
      LlmFailure(
        LlmFailureKind.credential,
        TransportText.noKey,
        endpoint: origin,
      ),
      null,
    );
  }
  return (null, 'Bearer $key');
}
