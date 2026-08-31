import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One request as the stub saw it, for asserting what was sent.
final class CapturedRequest {
  CapturedRequest(this.method, this.path, this.headers, this.body);

  final String method;
  final String path;
  final Map<String, String> headers;
  final String body;

  String? header(String name) => headers[name.toLowerCase()];
}

typedef StubHandler = Future<void> Function(HttpRequest request);

/// A loopback HTTP server scripted per test. Routes are `'METHOD /path'`
/// (paths relative to the origin, e.g. `POST /v1/chat/completions`); an
/// unrouted request answers 404. Every request is captured before its
/// handler runs, so a test can assert headers even when the handler
/// hangs or aborts.
final class StubServer {
  StubServer._(this._server, this.https);

  final HttpServer _server;
  final bool https;
  final routes = <String, StubHandler>{};
  final requests = <CapturedRequest>[];

  /// Completes each time a request has been captured.
  final _seen = StreamController<CapturedRequest>.broadcast();
  Stream<CapturedRequest> get seen => _seen.stream;

  static Future<StubServer> start({SecurityContext? tls}) async {
    final server = tls == null
        ? await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
        : await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls);
    final stub = StubServer._(server, tls != null);
    server.listen(stub._serve);
    return stub;
  }

  int get port => _server.port;
  String get origin => '${https ? 'https' : 'http'}://127.0.0.1:$port';
  Uri get v1 => Uri.parse('$origin/v1');

  /// The server's live socket view — how many connections are open or
  /// idle right now — for asserting keep-alive lifecycles (#109).
  HttpConnectionsInfo connectionsInfo() => _server.connectionsInfo();

  Future<void> _serve(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final headers = <String, String>{};
    request.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join(', '));
    final captured = CapturedRequest(
      request.method,
      request.uri.path,
      headers,
      body,
    );
    requests.add(captured);
    _seen.add(captured);
    final handler = routes['${request.method} ${request.uri.path}'];
    if (handler == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    try {
      await handler(request);
    } catch (_) {
      // The client went away mid-answer; that is the test's business.
    }
  }

  Future<void> close() async {
    await _server.close(force: true);
    await _seen.close();
  }

  // Answer helpers.

  /// Answers [status] with a JSON [body].
  static Future<void> json(
    HttpRequest request,
    Object body, {
    int status = 200,
  }) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  }

  /// Opens an SSE response and returns the sink; call [sseEvent] on it.
  static HttpResponse sse(HttpRequest request) {
    final response = request.response
      ..statusCode = 200
      ..headers.contentType = ContentType('text', 'event-stream')
      ..bufferOutput = false;
    return response;
  }

  static void event(HttpResponse response, Object data, {bool json = true}) {
    response.write('data: ${json ? jsonEncode(data) : data}\n\n');
  }

  /// A whole well-formed streamed answer: [words] as content deltas, a
  /// finish chunk, an optional usage chunk (with llama.cpp timings when
  /// [tokensPerSecond] is given), then `[DONE]`.
  static Future<void> stream(
    HttpRequest request,
    List<String> words, {
    String id = 'chatcmpl-1',
    String model = 'm',
    String finish = 'stop',
    bool usage = true,
    double? tokensPerSecond,
    Duration gap = Duration.zero,
  }) async {
    final response = sse(request);
    for (final w in words) {
      event(response, chunk(w, id: id, model: model));
      if (gap != Duration.zero) await Future<void>.delayed(gap);
    }
    event(response, {
      'id': id,
      'model': model,
      'choices': [
        {'index': 0, 'delta': {}, 'finish_reason': finish},
      ],
      if (tokensPerSecond != null)
        'timings': {'predicted_per_second': tokensPerSecond},
    });
    if (usage) {
      event(response, {
        'id': id,
        'model': model,
        'choices': [],
        'usage': {
          'prompt_tokens': 7,
          'completion_tokens': words.length,
          'total_tokens': 7 + words.length,
        },
      });
    }
    event(response, '[DONE]', json: false);
    await response.close();
  }

  static Map<String, Object?> chunk(
    String content, {
    String id = 'chatcmpl-1',
    String model = 'm',
    String? reasoning,
  }) => {
    'id': id,
    'object': 'chat.completion.chunk',
    'model': model,
    'choices': [
      {
        'index': 0,
        'delta': {
          if (reasoning != null)
            'reasoning_content': reasoning
          else
            'content': content,
        },
        'finish_reason': null,
      },
    ],
  };
}

/// A throwaway self-signed certificate for `localhost`, made with the
/// system `openssl` into [dir]; null when there is no `openssl`. Nothing
/// is committed: the point is a certificate no client trusts.
Future<SecurityContext?> selfSignedContext(Directory dir) async {
  final key = '${dir.path}/key.pem';
  final cert = '${dir.path}/cert.pem';
  final ProcessResult result;
  try {
    result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      key,
      '-out',
      cert,
      '-days',
      '1',
      '-subj',
      '/CN=localhost',
    ]);
  } on ProcessException {
    return null;
  }
  if (result.exitCode != 0) return null;
  return SecurityContext()
    ..useCertificateChain(cert)
    ..usePrivateKey(key);
}
