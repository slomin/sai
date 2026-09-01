import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A loopback OpenAI-compatible stub for the dialog tests: a fixed model
/// list and a scripted streamed answer. The transport itself is tested
/// in `sai_core`; here it only has to look like a server.
final class StubServer {
  StubServer._(this._server);

  final HttpServer _server;
  final requests = <String>[];
  List<String> words = const ['ready'];
  double? tokensPerSecond = 33.3;
  int chatStatus = 200;
  int zdrStatus = 200;

  /// Holds the zero-retention answer until completed, for a test that
  /// types while the list is being read.
  Completer<void>? zdrGate;

  /// Extra `owner/model-NN` rows in the zero-retention answer, for a
  /// test that needs a list taller than the suggestions box.
  int zdrExtra = 0;

  /// The OpenAI Responses route (#26): the model list `GET /v1/models`
  /// answers when set (OpenAI's shape), and how `POST /v1/responses`
  /// answers — the streamed [words], or [responsesStatus] with an error
  /// object naming [responsesParam].
  List<String>? openAiModels;
  int responsesStatus = 200;
  String? responsesParam;
  String? responsesCode;

  /// Every `POST /v1/responses` body, decoded, for asserting the pair.
  final responsesBodies = <Map<String, Object?>>[];

  static Future<StubServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final stub = StubServer._(server);
    server.listen(stub._serve);
    return stub;
  }

  String get origin => 'http://127.0.0.1:${_server.port}';
  String get v1 => '$origin/v1';

  Future<void> _serve(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    requests.add('${request.method} ${request.uri.path}');
    final response = request.response;
    switch ('${request.method} ${request.uri.path}') {
      case 'GET /v1/models' when openAiModels != null:
        response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'object': 'list',
              'data': [
                for (final id in openAiModels!) {'id': id, 'object': 'model'},
              ],
            }),
          );
      case 'POST /v1/responses' when responsesStatus != 200:
        responsesBodies.add(jsonDecode(body) as Map<String, Object?>);
        response
          ..statusCode = responsesStatus
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'error': {
                'type': 'invalid_request_error',
                'code': responsesCode ?? 'unsupported_value',
                'param': responsesParam,
                'message': 'the stub refuses (sk-canary quoted here)',
              },
            }),
          );
      case 'POST /v1/responses':
        responsesBodies.add(jsonDecode(body) as Map<String, Object?>);
        response
          ..headers.contentType = ContentType('text', 'event-stream')
          ..bufferOutput = false;
        for (final w in words) {
          response.write(
            'data: ${jsonEncode({'type': 'response.output_text.delta', 'item_id': 'msg_1', 'delta': w})}\n\n',
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        response.write(
          'data: ${jsonEncode({
            'type': 'response.completed',
            'response': {
              'id': 'resp_1',
              'model': 'gpt-5.6-sol-2026-08-01',
              'usage': {'input_tokens': 3, 'output_tokens': words.length, 'total_tokens': 3 + words.length},
            },
          })}\n\n',
        );
      case 'GET /v1/models':
        response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'data': [
                {'id': 'qwen'},
                {'id': 'embed'},
              ],
            }),
          );
      case 'GET /v1/key':
        // OpenRouter's key check (#24): the probe reads nothing of it.
        response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'data': {'limit': 1, 'usage': 0},
            }),
          );
      case 'GET /v1/endpoints/zdr' when zdrStatus != 200:
        response
          ..statusCode = zdrStatus
          ..write('{"error":"no"}');
      case 'GET /v1/endpoints/zdr':
        // OpenRouter's zero-retention list (#112): one row per endpoint —
        // two hosts for one model, a router, a malformed row, a variant.
        if (zdrGate case final gate?) await gate.future;
        response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'data': [
                for (var i = 0; i < zdrExtra; i++)
                  {'model_id': 'owner/model-${i.toString().padLeft(2, '0')}'},
                {
                  'model_id': 'qwen/qwen3-235b-a22b',
                  'model_name': 'Qwen3 235B',
                  'provider_name': 'DeepInfra',
                },
                {
                  'model_id': 'deepseek/deepseek-v4-flash-0731',
                  'provider_name': 'DeepInfra',
                },
                {
                  'model_id': 'deepseek/deepseek-v4-flash-0731',
                  'provider_name': 'GMICloud',
                },
                {'model_id': 'openrouter/auto'},
                {'name': 'no id'},
                {'model_id': 'z-ai/glm-5.2:free'},
              ],
            }),
          );
      case 'POST /v1/chat/completions' when chatStatus != 200:
        response
          ..statusCode = chatStatus
          ..write('{"error":"no"}');
      case 'POST /v1/chat/completions':
        response
          ..headers.contentType = ContentType('text', 'event-stream')
          ..bufferOutput = false;
        for (final w in words) {
          response.write(
            'data: ${jsonEncode({
              'id': 'chatcmpl-1',
              'choices': [
                {
                  'index': 0,
                  'delta': {'content': w},
                  'finish_reason': null,
                },
              ],
            })}\n\n',
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        response.write(
          'data: ${jsonEncode({
            'id': 'chatcmpl-1',
            'choices': [
              {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
            ],
            if (tokensPerSecond != null) 'timings': {'predicted_per_second': tokensPerSecond},
          })}\n\n',
        );
        response.write('data: [DONE]\n\n');
      default:
        response.statusCode = HttpStatus.notFound;
    }
    try {
      await response.close();
    } catch (_) {}
  }

  Future<void> close() => _server.close(force: true);
}
