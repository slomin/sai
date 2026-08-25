import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:sai_core/src/llm/openai_compatible/policy.dart';
import 'package:test/test.dart';

import '../stub_server.dart';

const quick = OpenAiDeadlines(
  connect: Duration(seconds: 2),
  firstResponse: Duration(milliseconds: 400),
  interToken: Duration(milliseconds: 400),
);

void main() {
  late StubServer stub;
  late InMemorySecretStore secrets;

  setUp(() async {
    stub = await StubServer.start();
    secrets = InMemorySecretStore();
    stub.routes['GET /v1/models'] = (req) => StubServer.json(req, {
      'object': 'list',
      'data': [
        {'id': 'qwen', 'object': 'model'},
        {'id': 'embed', 'object': 'model'},
      ],
    });
  });
  tearDown(() => stub.close());

  OpenAiCompatibleProvider make({String? credential, String? origin}) =>
      OpenAiCompatibleProvider(
        id: 'lan',
        endpoint: stub.v1,
        defaultModel: 'qwen',
        secrets: secrets,
        credential: credential,
        credentialOrigin: origin,
        deadlines: quick,
      );

  test('llama.cpp: health, props and models', () async {
    stub.routes['GET /health'] = (req) =>
        StubServer.json(req, {'status': 'ok'});
    stub.routes['GET /props'] = (req) => StubServer.json(req, {
      'default_generation_settings': {'n_ctx': 8192},
      'total_slots': 1,
      'model_path': '/models/q.gguf',
    });
    final info = await make().probe();
    expect(info.health, EndpointHealth.ok);
    expect(info.models, ['qwen', 'embed']);
    expect(info.contextWindow, 8192);
    expect(info.serverKind, 'llama.cpp');
    expect(info.failure, isNull);
    expect(stub.requests.map((r) => r.path).toSet(), {
      '/v1/models',
      '/health',
      '/api/v1/models',
      '/props',
    });
  });

  test('llama.cpp still loading', () async {
    stub.routes['GET /health'] = (req) => StubServer.json(req, {
      'error': {'code': 503, 'message': 'Loading model'},
    }, status: 503);
    final info = await make().probe();
    expect(info.health, EndpointHealth.loading);
    expect(info.serverKind, 'llama.cpp');
    expect(info.contextWindow, isNull, reason: 'props answered 404');
  });

  test('LM Studio: the loaded instance of the default model', () async {
    stub.routes['GET /api/v1/models'] = (req) => StubServer.json(req, {
      'models': [
        {
          'type': 'llm',
          'key': 'qwen',
          'loaded_instances': [
            {
              'id': 'qwen',
              'config': {'context_length': 86016},
            },
          ],
          'max_context_length': 262144,
        },
        {'type': 'embedding', 'key': 'embed', 'loaded_instances': []},
      ],
    });
    final info = await make().probe();
    expect(info.health, EndpointHealth.ok);
    expect(info.serverKind, 'lmstudio');
    expect(info.contextWindow, 86016);
    expect(info.models, ['qwen', 'embed']);
  });

  test('LM Studio with the default model not loaded says no context', () async {
    stub.routes['GET /api/v1/models'] = (req) => StubServer.json(req, {
      'models': [
        {
          'type': 'llm',
          'key': 'qwen',
          'loaded_instances': [],
          'max_context_length': 4096,
        },
      ],
    });
    final info = await make().probe();
    expect(info.serverKind, 'lmstudio');
    expect(info.contextWindow, isNull, reason: 'not guessed from the maximum');
  });

  test('a 200 with an error body on /health is not llama.cpp', () async {
    // LM Studio answers every unknown path this way.
    for (final path in ['/health', '/props']) {
      stub.routes['GET $path'] = (req) => StubServer.json(req, {
        'error': 'Unexpected endpoint or method. (GET $path)',
      });
    }
    stub.routes['GET /api/v1/models'] = (req) => StubServer.json(req, {
      'models': [
        {'type': 'llm', 'key': 'qwen', 'loaded_instances': []},
      ],
    });
    final info = await make().probe();
    expect(info.serverKind, 'lmstudio');
    expect(info.health, EndpointHealth.ok);
  });

  test('a server that only speaks /v1 is ok with no extras', () async {
    final info = await make().probe();
    expect(info.health, EndpointHealth.ok);
    expect(info.models, ['qwen', 'embed']);
    expect(info.serverKind, isNull);
    expect(info.contextWindow, isNull);
  });

  test('unreachable, rejected, and refused before a socket', () async {
    final gone = await StubServer.start();
    final endpoint = gone.v1;
    await gone.close();
    final down = OpenAiCompatibleProvider(
      id: 'lan',
      endpoint: endpoint,
      defaultModel: 'qwen',
      secrets: secrets,
      deadlines: quick,
    );
    var info = await down.probe();
    expect(info.health, EndpointHealth.unavailable);
    expect(info.failure!.kind, LlmFailureKind.unreachable);
    expect(info.failure!.message, TransportText.couldNotConnect);

    stub.routes['GET /v1/models'] = (req) =>
        StubServer.json(req, {'error': 'nope'}, status: 401);
    secrets.write('provider:lan', 'k');
    info = await make(credential: 'provider:lan', origin: stub.origin).probe();
    expect(info.health, EndpointHealth.unavailable);
    expect(info.failure!.kind, LlmFailureKind.rejected);
    expect(info.failure!.status, 401);
    expect(stub.requests.single.header('authorization'), 'Bearer k');

    info = await make(credential: 'provider:lan', origin: 'https://x').probe();
    expect(info.failure!.kind, LlmFailureKind.credential);
    expect(stub.requests, hasLength(1), reason: 'nothing more was sent');
  });

  test('an answer past the size cap is refused, not buffered', () async {
    stub.routes['GET /v1/models'] = (req) async {
      req.response.headers.contentType = ContentType.json;
      final chunk = List.filled(64 << 10, 0x20);
      for (var i = 0; i < 40; i++) {
        req.response.add(chunk);
        await req.response.flush();
      }
      await req.response.close();
    };
    final info = await make().probe();
    expect(info.failure!.kind, LlmFailureKind.protocol);
    expect(info.failure!.message, TransportText.tooLarge);
  });

  test('a redirect on discovery is refused too', () async {
    stub.routes['GET /v1/models'] = (req) async {
      req.response
        ..statusCode = 302
        ..headers.set('location', 'https://elsewhere.example/v1/models');
      await req.response.close();
    };
    final info = await make().probe();
    expect(info.failure!.kind, LlmFailureKind.rejected);
    expect(info.failure!.message, TransportText.redirected);
  });

  test('non-JSON where JSON was expected is a protocol failure', () async {
    stub.routes['GET /v1/models'] = (req) async {
      req.response.write('<html>');
      await req.response.close();
    };
    final info = await make().probe();
    expect(info.failure!.kind, LlmFailureKind.protocol);
    expect(info.failure!.message, TransportText.notJson);
  });
}
