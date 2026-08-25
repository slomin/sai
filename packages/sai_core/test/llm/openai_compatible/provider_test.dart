import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:sai_core/src/llm/openai_compatible/chunks.dart';
import 'package:sai_core/src/llm/openai_compatible/policy.dart';
import 'package:test/test.dart';

import '../provider_contract.dart';
import '../stub_server.dart';

LlmRequest ask(String text, {bool? reasoning, String? model}) => LlmRequest(
  messages: [LlmMessage(LlmRole.user, text)],
  reasoning: reasoning,
  model: model,
);

const canary = 'sk-canary-3c9e1a7b5d2f4e6a8c0b1d3f5a7c9e2b';

/// Short deadlines so the timeout tests finish quickly, with wide margins
/// against a slow runner: what must finish in time takes milliseconds,
/// what must time out never answers at all.
const quick = OpenAiDeadlines(
  connect: Duration(seconds: 2),
  firstResponse: Duration(milliseconds: 400),
  firstToken: Duration(milliseconds: 1200),
  interToken: Duration(milliseconds: 400),
);

void main() {
  late StubServer stub;
  late InMemorySecretStore secrets;

  setUp(() async {
    stub = await StubServer.start();
    secrets = InMemorySecretStore();
  });
  tearDown(() => stub.close());

  OpenAiCompatibleProvider make({
    Uri? endpoint,
    String? credential,
    String? credentialOrigin,
    SecretStore? store,
    OpenAiDeadlines deadlines = quick,
    String defaultModel = 'qwen',
  }) => OpenAiCompatibleProvider(
    id: 'lan',
    endpoint: endpoint ?? stub.v1,
    defaultModel: defaultModel,
    secrets: store ?? secrets,
    credential: credential,
    credentialOrigin: credentialOrigin,
    deadlines: deadlines,
  );

  void answerWith(List<String> words, {double? tokensPerSecond}) {
    stub.routes['POST /v1/chat/completions'] = (req) =>
        StubServer.stream(req, words, tokensPerSecond: tokensPerSecond);
  }

  group('against a stub that streams', () {
    setUp(() => answerWith(['one ', 'two ', 'three']));
    llmProviderContract(
      'OpenAiCompatibleProvider',
      () => make(),
      request: () => ask('go'),
    );
  });

  test('sends an OpenAI streaming request and reads the answer back', () async {
    answerWith(['hello ', 'world'], tokensPerSecond: 42.5);
    final provider = make();
    final result = await provider.start(ask('hi')).done;
    expect(result.finish, LlmFinish.stop);
    expect(result.text, 'hello world');
    expect(result.model.provider, 'lan');
    expect(result.model.id, 'qwen');
    expect(result.model.requestId, 'chatcmpl-1');
    expect(result.usage!.promptTokens, 7);
    expect(result.usage!.completionTokens, 2);
    expect(result.usage!.tokensPerSecond, 42.5);
    final sent = stub.requests.single;
    expect(sent.path, '/v1/chat/completions');
    expect(sent.header('content-type'), startsWith('application/json'));
    expect(sent.header('accept'), 'text/event-stream');
    expect(sent.header('authorization'), isNull, reason: 'keyless');
    expect(sent.body, contains('"stream":true'));
    expect(sent.body, contains('"include_usage":true'));
    expect(sent.body, contains('"model":"qwen"'));
    expect(sent.body, contains('"content":"hi"'));
    expect(provider.displayName, 'lan @ ${stub.origin}');
    expect(provider.privacy, LlmPrivacy.local);
    await provider.close();
  });

  test('a length finish, and a stream without usage', () async {
    stub.routes['POST /v1/chat/completions'] = (req) =>
        StubServer.stream(req, ['a'], finish: 'length', usage: false);
    final result = await make().start(ask('x')).done;
    expect(result.finish, LlmFinish.length);
    expect(result.usage, isNull);
  });

  group('the key', () {
    test(
      'is sent as a bearer token only to the origin it was entered for',
      () async {
        answerWith(['ok']);
        secrets.write('provider:lan', canary);
        final bound = make(
          credential: 'provider:lan',
          credentialOrigin: stub.origin,
        );
        expect((await bound.start(ask('x')).done).finish, LlmFinish.stop);
        expect(stub.requests.single.header('authorization'), 'Bearer $canary');

        final moved = make(
          credential: 'provider:lan',
          credentialOrigin: 'https://other.example',
        );
        final result = await moved.start(ask('x')).done;
        expect(result.finish, LlmFinish.failed);
        expect(result.failure!.kind, LlmFailureKind.credential);
        expect(result.failure!.message, TransportText.keyElsewhere);
        expect(stub.requests, hasLength(1), reason: 'nothing was sent');

        final unbound = make(credential: 'provider:lan');
        expect(
          (await unbound.start(ask('x')).done).failure!.message,
          TransportText.keyElsewhere,
        );
        expect(stub.requests, hasLength(1));
        // The binding is live: the registry can set it on a running provider.
        unbound.credentialOrigin = stub.origin;
        expect((await unbound.start(ask('x')).done).finish, LlmFinish.stop);
        expect(stub.requests, hasLength(2));
      },
    );

    test('missing, or an unreadable store, fails before any socket', () async {
      answerWith(['ok']);
      final missing = make(
        credential: 'provider:lan',
        credentialOrigin: stub.origin,
      );
      var result = await missing.start(ask('x')).done;
      expect(result.failure!.kind, LlmFailureKind.credential);
      expect(result.failure!.message, TransportText.noKey);
      // "no key" comes before "another endpoint": a provider added with
      // --key and no key yet is told to enter one, not to re-enter one.
      final fresh = make(credential: 'provider:lan');
      expect(
        (await fresh.start(ask('x')).done).failure!.message,
        TransportText.noKey,
      );
      final broken = make(
        credential: 'provider:lan',
        credentialOrigin: stub.origin,
        store: _BrokenStore(),
      );
      result = await broken.start(ask('x')).done;
      expect(result.failure!.message, TransportText.keychainUnavailable);
      expect(stub.requests, isEmpty);
    });
  });

  group('the transport policy', () {
    test('does not follow a redirect, and forwards nothing', () async {
      final elsewhere = await StubServer.start();
      addTearDown(elsewhere.close);
      elsewhere.routes['POST /v1/chat/completions'] = (req) =>
          StubServer.stream(req, ['leaked']);
      stub.routes['POST /v1/chat/completions'] = (req) async {
        req.response
          ..statusCode = 307
          ..headers.set('location', '${elsewhere.origin}/v1/chat/completions');
        await req.response.close();
      };
      secrets.write('provider:lan', canary);
      final provider = make(
        credential: 'provider:lan',
        credentialOrigin: stub.origin,
      );
      final result = await provider.start(ask('x')).done;
      expect(result.finish, LlmFinish.failed);
      expect(result.failure!.kind, LlmFailureKind.rejected);
      expect(result.failure!.status, 307);
      expect(result.failure!.message, TransportText.redirected);
      expect(result.failure!.endpoint, stub.origin);
      expect(elsewhere.requests, isEmpty);
    });

    test(
      'refuses plaintext beyond this machine and the LAN, without connecting',
      () async {
        for (final host in ['lan.example', '203.0.113.1']) {
          final provider = make(endpoint: Uri.parse('http://$host:1/v1'));
          final result = await provider.start(ask('x')).done;
          expect(result.failure!.kind, LlmFailureKind.unreachable);
          expect(result.failure!.message, TransportText.plaintext);
          expect(result.failure!.endpoint, 'http://$host:1');
        }
      },
    );

    test(
      'a certificate nobody trusts is a handshake failure, not bypassed',
      () async {
        final dir = Directory.systemTemp.createTempSync('sai_tls_test');
        addTearDown(() => dir.deleteSync(recursive: true));
        final tls = await selfSignedContext(dir);
        if (tls == null) {
          markTestSkipped('no openssl on this machine');
          return;
        }
        final secure = await StubServer.start(tls: tls);
        addTearDown(secure.close);
        secure.routes['POST /v1/chat/completions'] = (req) =>
            StubServer.stream(req, ['no']);
        final provider = make(endpoint: secure.v1);
        final result = await provider.start(ask('x')).done;
        expect(result.failure!.kind, LlmFailureKind.unreachable);
        expect(result.failure!.message, TransportText.tls);
        expect(result.failure!.endpoint, secure.origin);
        expect(result.text, isEmpty);
      },
    );

    test('an HTTP(S)_PROXY in the environment is ignored', () async {
      // The default HttpClient honours the environment, which only a
      // fresh process can carry: run the probe script under a proxy that
      // does not exist and expect the direct call to succeed anyway.
      answerWith(['direct']);
      final script = File(
        '${Directory.current.path}/test/llm/openai_compatible/proxy_probe.dart',
      );
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', script.path, stub.v1.toString()],
        environment: {
          'HTTP_PROXY': 'http://127.0.0.1:1',
          'http_proxy': 'http://127.0.0.1:1',
          'HTTPS_PROXY': 'http://127.0.0.1:1',
          'https_proxy': 'http://127.0.0.1:1',
        },
      );
      expect(
        result.stdout,
        contains('stop direct'),
        reason: '${result.stderr}',
      );
      expect(stub.requests, hasLength(1));
    });
  });

  group('answers that are not a stream', () {
    test('a 401 blames the key, other statuses are named', () async {
      for (final (status, message) in [
        (401, TransportText.rejectedKey),
        (403, TransportText.rejectedKey),
        (500, 'the endpoint answered 500'),
        (404, 'the endpoint answered 404'),
      ]) {
        stub.routes['POST /v1/chat/completions'] = (req) =>
            StubServer.json(req, {'error': 'no: $canary'}, status: status);
        final result = await make().start(ask('x')).done;
        expect(result.failure!.kind, LlmFailureKind.rejected);
        expect(result.failure!.status, status);
        expect(result.failure!.message, message);
        expect(result.toString(), isNot(contains(canary)));
      }
    });

    test(
      'a JSON body where a stream was asked for is a protocol failure',
      () async {
        stub.routes['POST /v1/chat/completions'] = (req) =>
            StubServer.json(req, {'choices': []});
        final result = await make().start(ask('x')).done;
        expect(result.failure!.kind, LlmFailureKind.protocol);
        expect(result.failure!.message, TransportText.notAStream);
      },
    );

    test('an unreadable chunk, and a stream cut short', () async {
      stub.routes['POST /v1/chat/completions'] = (req) async {
        final r = StubServer.sse(req);
        StubServer.event(r, StubServer.chunk('a'));
        StubServer.event(r, 'not json $canary', json: false);
        await r.close();
      };
      var result = await make().start(ask('x')).done;
      expect(result.text, 'a');
      expect(result.failure!.kind, LlmFailureKind.protocol);
      expect(result.failure!.message, TransportText.badChunk);
      expect(result.toString(), isNot(contains(canary)));

      stub.routes['POST /v1/chat/completions'] = (req) async {
        final r = StubServer.sse(req);
        StubServer.event(r, StubServer.chunk('a'));
        StubServer.event(r, StubServer.chunk('b'));
        await r.close();
      };
      result = await make().start(ask('x')).done;
      expect(result.text, 'ab');
      expect(result.failure!.kind, LlmFailureKind.protocol);
      expect(result.failure!.message, TransportText.endedEarly);
    });

    test('an error object inside the stream is a rejection', () async {
      stub.routes['POST /v1/chat/completions'] = (req) async {
        final r = StubServer.sse(req);
        StubServer.event(r, StubServer.chunk('a'));
        StubServer.event(r, {
          'error': {'message': 'context length exceeded $canary', 'code': 400},
        });
        StubServer.event(r, '[DONE]', json: false);
        await r.close();
      };
      final result = await make().start(ask('x')).done;
      expect(result.text, 'a');
      expect(result.finish, LlmFinish.failed);
      expect(result.failure!.kind, LlmFailureKind.rejected);
      expect(result.failure!.message, TransportText.errorPayload);
      expect(result.toString(), isNot(contains(canary)));
    });

    test('nothing listening is unreachable, naming the origin', () async {
      final closed = await StubServer.start();
      final origin = closed.origin;
      final endpoint = closed.v1;
      await closed.close();
      final result = await make(endpoint: endpoint).start(ask('x')).done;
      expect(result.failure!.kind, LlmFailureKind.unreachable);
      expect(result.failure!.message, TransportText.couldNotConnect);
      expect(result.failure!.endpoint, origin);
    });
  });

  group('deadlines', () {
    test('no response headers in time', () async {
      stub.routes['POST /v1/chat/completions'] = (req) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        await req.response.close();
      };
      final result = await make().start(ask('x')).done;
      expect(result.failure!.kind, LlmFailureKind.timeout);
      expect(result.failure!.message, TransportText.noResponse);
    });

    test('a stream that stalls between tokens', () async {
      stub.routes['POST /v1/chat/completions'] = (req) async {
        final r = StubServer.sse(req);
        StubServer.event(r, StubServer.chunk('a'));
        await Future<void>.delayed(const Duration(seconds: 5));
        await r.close();
      };
      final result = await make().start(ask('x')).done;
      expect(result.text, 'a');
      expect(result.failure!.kind, LlmFailureKind.timeout);
      expect(result.failure!.message, TransportText.stalled);
    });

    test('the first token gets its own, longer deadline', () async {
      // Headers at once, then prompt evaluation longer than the
      // inter-token deadline but within the first-token one.
      stub.routes['POST /v1/chat/completions'] = (req) async {
        final r = StubServer.sse(req);
        // Headers (and a keep-alive) now, the token much later.
        r.write(': processing\n\n');
        await r.flush();
        await Future<void>.delayed(const Duration(milliseconds: 700));
        StubServer.event(r, StubServer.chunk('late'));
        StubServer.event(r, '[DONE]', json: false);
        await r.close();
      };
      final result = await make().start(ask('x')).done;
      expect(result.finish, LlmFinish.stop, reason: '${result.failure}');
      expect(result.text, 'late');
    });

    test('keep-alive comments hold a slow stream open', () async {
      stub.routes['POST /v1/chat/completions'] = (req) async {
        final r = StubServer.sse(req);
        StubServer.event(r, StubServer.chunk('a'));
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          r.write(': ping\n\n');
        }
        StubServer.event(r, StubServer.chunk('b'));
        StubServer.event(r, '[DONE]', json: false);
        await r.close();
      };
      final result = await make().start(ask('x')).done;
      expect(result.finish, LlmFinish.stop, reason: '${result.failure}');
      expect(result.text, 'ab');
    });

    test('a slow but moving stream is fine', () async {
      stub.routes['POST /v1/chat/completions'] = (req) => StubServer.stream(
        req,
        ['a', 'b', 'c', 'd'],
        gap: const Duration(milliseconds: 150),
      );
      final result = await make().start(ask('x')).done;
      expect(result.finish, LlmFinish.stop);
      expect(result.text, 'abcd');
    });
  });

  group('cancellation', () {
    test('before the response: the request is aborted', () async {
      final answered = Completer<void>();
      stub.routes['POST /v1/chat/completions'] = (req) async {
        await answered.future;
        await StubServer.stream(req, ['late']);
      };
      final provider = make(deadlines: const OpenAiDeadlines());
      final call = provider.start(ask('x'));
      await stub.seen.first;
      call.cancel();
      final result = await call.done;
      expect(result.finish, LlmFinish.cancelled);
      expect(result.text, isEmpty);
      answered.complete();
    });

    test('mid-stream: the text so far is kept', () async {
      stub.routes['POST /v1/chat/completions'] = (req) => StubServer.stream(
        req,
        ['a', 'b', 'c'],
        gap: const Duration(seconds: 1),
      );
      final provider = make(deadlines: const OpenAiDeadlines());
      final call = provider.start(ask('x'));
      await call.deltas.first;
      call.cancel();
      final result = await call.done;
      expect(result.finish, LlmFinish.cancelled);
      expect(result.text, 'a');
    });

    test('close() cancels and a later call is refused', () async {
      answerWith(['x']);
      final provider = make();
      await provider.close();
      final result = await provider.start(ask('x')).done;
      expect(result.failure!.kind, LlmFailureKind.internal);
      expect(result.failure!.message, TransportText.closed);
    });
  });

  test('every failure names the origin and uses fixed text', () async {
    // Collected from the cases above, cheaply: the checks happen there;
    // this pins the rule for any message the provider can produce.
    for (final text in TransportText.all) {
      expect(text, isNot(contains('://')));
      expect(text, isNot(contains('sk-')));
    }
    expect(
      TransportText.threw(StateError('sk-x http://u@h')),
      'transport threw: StateError',
    );
  });
  test('reasoning deltas are kept apart from the answer (#34)', () async {
    stub.routes['POST /v1/chat/completions'] = (req) async {
      final response = req.response;
      response.headers.contentType = ContentType('text', 'event-stream');
      response.bufferOutput = false;
      StubServer.event(response, StubServer.chunk('', reasoning: 'let me '));
      StubServer.event(response, StubServer.chunk('', reasoning: 'think'));
      StubServer.event(response, StubServer.chunk('ready.'));
      StubServer.event(response, {
        'id': 'chatcmpl-1',
        'object': 'chat.completion.chunk',
        'model': 'm',
        'choices': [
          {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
        ],
      });
      StubServer.event(response, '[DONE]', json: false);
      await response.close();
    };
    final provider = make();
    final call = provider.start(ask('go'));
    final deltas = await call.deltas.toList();
    final result = await call.done;
    expect(deltas.map((d) => (d.text, d.reasoning)), [
      ('let me ', true),
      ('think', true),
      ('ready.', false),
    ]);
    expect(result.text, 'ready.');
    expect(result.reasoning, 'let me think');
    await provider.close();
  });

  test('the loaded model names nothing on the wire and takes the '
      "backend's id", () async {
    stub.routes['POST /v1/chat/completions'] = (req) =>
        StubServer.stream(req, ['ok'], model: 'what-is-loaded');
    final provider = make(defaultModel: OpenAiCompatibleProvider.loadedModel);
    final result = await provider.start(ask('a')).done;
    expect(result.text, 'ok');
    expect(result.model.id, 'what-is-loaded');
    expect(
      (jsonDecode(stub.requests.single.body) as Map).containsKey('model'),
      isFalse,
    );
    // A request that names a model is sent as named.
    await provider.start(ask('b', model: 'named')).done;
    expect((jsonDecode(stub.requests.last.body) as Map)['model'], 'named');
    await provider.close();
  });

  test('a 400 to reasoning_effort is retried without it, once', () async {
    stub.routes['POST /v1/chat/completions'] = (req) async {
      final body = jsonDecode(stub.requests.last.body) as Map<String, Object?>;
      if (body.containsKey('reasoning_effort')) {
        req.response.statusCode = 400;
        await req.response.close();
        return;
      }
      await StubServer.stream(req, ['ok']);
    };
    final provider = make();
    final first = await provider.start(ask('a', reasoning: false)).done;
    expect(first.text, 'ok', reason: '$first ${first.failure}');
    final second = await provider.start(ask('b', reasoning: false)).done;
    expect(second.text, 'ok');
    expect(
      stub.requests.map(
        (r) => (jsonDecode(r.body) as Map).containsKey('reasoning_effort'),
      ),
      [true, false, false],
    );
    expect(
      stub.requests.map(
        (r) => (jsonDecode(r.body) as Map).containsKey('chat_template_kwargs'),
      ),
      [true, false, false],
    );
    await provider.close();
  });

  test('a backend that accepts the switch is left alone', () async {
    stub.routes['POST /v1/chat/completions'] = (req) =>
        StubServer.stream(req, ['ok']);
    final provider = make();
    await provider.start(ask('a', reasoning: false)).done;
    await provider.start(ask('b')).done;
    expect(
      stub.requests.map((r) => (jsonDecode(r.body) as Map)['reasoning_effort']),
      ['none', null],
    );
    // llama-server reads the template switch, not reasoning_effort (#23).
    expect(
      stub.requests.map(
        (r) => (jsonDecode(r.body) as Map)['chat_template_kwargs'],
      ),
      [
        {'enable_thinking': false},
        null,
      ],
    );
    await provider.close();
  });

  test('ChatChunk.parse reads reasoning_content and reasoning', () {
    expect(
      ChatChunk.parse('{"choices":[{"delta":{"reasoning_content":"hm"}}]}')
          .reasoning,
      'hm',
    );
    expect(
      ChatChunk.parse('{"choices":[{"delta":{"reasoning":"hm2"}}]}').reasoning,
      'hm2',
    );
    final plain = ChatChunk.parse('{"choices":[{"delta":{"content":"a"}}]}');
    expect(plain.reasoning, isNull);
    expect(plain.content, 'a');
  });
}

final class _BrokenStore implements SecretStore {
  @override
  String? read(String account) =>
      throw const SecretStoreException('keychain locked', status: -25308);
  @override
  bool has(String account) => throw const SecretStoreException('locked');
  @override
  void write(String account, String value) => throw UnimplementedError();
  @override
  bool delete(String account) => throw UnimplementedError();
}
