import 'dart:convert';

import 'package:sai_core/sai_core.dart';
import 'package:sai_core/src/llm/openai_compatible/policy.dart';
import 'package:test/test.dart';

import 'provider_contract.dart';
import 'stub_server.dart';

/// The OpenRouter dialect (#24) over the common transport, against a
/// loopback stub: what goes on the wire, how a refusal reads, that the key
/// is read at call time and never sent anywhere else, and the probe.
void main() {
  const canary =
      'sk-canary-9d8c7b6a5f4e3d2c1b0a9f8e7d6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1f0e9d8c';
  late StubServer stub;
  late InMemorySecretStore secrets;
  const quick = OpenAiDeadlines(
    connect: Duration(seconds: 2),
    firstResponse: Duration(seconds: 2),
    firstToken: Duration(seconds: 2),
    interToken: Duration(seconds: 2),
  );

  setUp(() async {
    stub = await StubServer.start();
    secrets = InMemorySecretStore();
    secrets.write('provider:openrouter', canary);
  });
  tearDown(() => stub.close());

  OpenAiCompatibleProvider make({
    OpenRouterRouting routing = OpenRouterRouting.deepinfraFp8,
    String model = openRouterPresetModel,
    SecretStore? store,
  }) => OpenAiCompatibleProvider(
    id: 'openrouter',
    endpoint: stub.v1,
    defaultModel: model,
    secrets: store ?? secrets,
    credential: 'provider:openrouter',
    privacy: LlmPrivacy.cloud,
    deadlines: quick,
    dialect: OpenRouterDialect(routing),
  );

  LlmRequest ask(String text, {bool? reasoning}) => LlmRequest(
    messages: [LlmMessage(LlmRole.user, text)],
    maxTokens: 64,
    temperature: 0,
    reasoning: reasoning,
  );

  void answerWith(List<String> words) {
    stub.routes['POST /v1/chat/completions'] = (req) => StubServer.stream(
      req,
      words,
      id: 'gen-1',
      model: openRouterPresetModel,
    );
  }

  group('against a stub that streams', () {
    setUp(() => answerWith(['one ', 'two ', 'three']));
    llmProviderContract(
      'OpenAiCompatibleProvider(OpenRouterDialect)',
      () => make(),
      request: () => ask('go'),
    );
  });

  test('the recommended preset sends exactly the pinned routing', () async {
    answerWith(['ready']);
    final result = await make().start(ask('hi')).done;
    expect(result.finish, LlmFinish.stop);
    expect(result.model.id, openRouterPresetModel);
    expect(result.model.requestId, 'gen-1');
    final sent = stub.requests.single;
    final body = jsonDecode(sent.body) as Map<String, Object?>;
    expect(body['model'], openRouterPresetModel);
    expect(body['provider'], {
      'only': ['deepinfra'],
      'quantizations': ['fp8'],
      'allow_fallbacks': false,
      'require_parameters': true,
      'data_collection': 'deny',
      'zdr': true,
    });
    expect(body['stream'], isTrue);
    expect(body['max_tokens'], 64);
    expect(body['temperature'], 0);
    // Local-backend fields never go to OpenRouter: `require_parameters`
    // would refuse them, and the usage comes in the final chunk anyway.
    expect(body, isNot(contains('stream_options')));
    expect(body, isNot(contains('chat_template_kwargs')));
    expect(body, isNot(contains('reasoning_effort')));
    expect(body, isNot(contains('reasoning')), reason: 'reasoning left on');
    expect(body, isNot(contains('models')), reason: 'no fallback array');
    expect(sent.header('authorization'), 'Bearer $canary');
    expect(sent.header('http-referer'), 'https://github.com/slomin/sai');
    expect(sent.header('x-openrouter-title'), 'SAI');
    expect(sent.header('accept'), 'text/event-stream');
  });

  test('an exact model keeps the privacy filters and drops the pin', () async {
    answerWith(['ok']);
    await make(
      routing: OpenRouterRouting.exact,
      model: 'qwen/qwen3-8b',
    ).start(ask('hi')).done;
    final body = jsonDecode(stub.requests.single.body) as Map<String, Object?>;
    expect(body['model'], 'qwen/qwen3-8b');
    expect(body['provider'], {
      'require_parameters': true,
      'data_collection': 'deny',
      'zdr': true,
    });
  });

  test(
    'reasoning off is said OpenRouter\'s way, once, with no ladder',
    () async {
      answerWith(['ok']);
      await make().start(ask('hi', reasoning: false)).done;
      final body =
          jsonDecode(stub.requests.single.body) as Map<String, Object?>;
      expect(body['reasoning'], {'enabled': false});
      expect(body, isNot(contains('chat_template_kwargs')));
      expect(body, isNot(contains('reasoning_effort')));

      // A 400 is a refusal, not a retry without the switch.
      stub.requests.clear();
      stub.routes['POST /v1/chat/completions'] = (req) => StubServer.json(req, {
        'error': {'code': 400, 'message': 'no reasoning $canary'},
      }, status: 400);
      final result = await make().start(ask('hi', reasoning: false)).done;
      expect(result.finish, LlmFinish.failed);
      expect(result.failure!.kind, LlmFailureKind.rejected);
      expect(result.failure!.message, TransportText.answered(400));
      expect(result.failure!.toString(), isNot(contains(canary)));
      expect(stub.requests, hasLength(1), reason: 'no second attempt');
    },
  );

  test('a missing route, an empty account and a bad key read fixed', () async {
    Future<LlmFailure> refuse(
      int status, {
      OpenAiCompatibleProvider? via,
    }) async {
      stub.routes['POST /v1/chat/completions'] = (req) => StubServer.json(req, {
        'error': {'code': status, 'message': 'body $canary'},
      }, status: status);
      final result = await (via ?? make()).start(ask('hi')).done;
      expect(result.failure!.kind, LlmFailureKind.rejected);
      expect(result.failure!.toString(), isNot(contains(canary)));
      expect(result.failure!.endpoint, stub.origin);
      expect(result.failure!.status, status);
      return result.failure!;
    }

    expect((await refuse(404)).message, TransportText.noRoute);
    expect((await refuse(402)).message, TransportText.noCredit);
    expect((await refuse(401)).message, TransportText.rejectedKey);
    expect((await refuse(429)).message, TransportText.answered(429));
    // Under exact routing there is no pin: a 404 is the model missing or
    // the privacy filters leaving no endpoint for it (#115).
    expect(
      (await refuse(
        404,
        via: make(routing: OpenRouterRouting.exact, model: 'qwen/qwen3-8b'),
      )).message,
      TransportText.noExactEndpoint,
    );
    expect(
      OpenRouterRouting.exact.noEndpointText,
      TransportText.noExactEndpoint,
    );
    expect(
      OpenRouterRouting.deepinfraFp8.noEndpointText,
      TransportText.noRoute,
    );
    for (final f in [
      TransportText.noRoute,
      TransportText.noExactEndpoint,
      TransportText.noCredit,
    ]) {
      expect(TransportText.all, contains(f));
    }
  });

  test('an error mid-stream ends the call without its text', () async {
    stub.routes['POST /v1/chat/completions'] = (req) async {
      final r = StubServer.sse(req);
      StubServer.event(r, StubServer.chunk('part', id: 'gen-2'));
      StubServer.event(r, {
        'id': 'gen-2',
        'error': {'code': 502, 'message': 'upstream $canary'},
        'choices': [
          {'index': 0, 'delta': {}, 'finish_reason': 'error'},
        ],
      });
      await r.close();
    };
    final result = await make().start(ask('hi')).done;
    expect(result.finish, LlmFinish.failed);
    expect(result.failure!.message, TransportText.errorPayload);
    expect(result.toString(), isNot(contains(canary)));
  });

  test('the cost OpenRouter reports lands on the usage', () async {
    stub.routes['POST /v1/chat/completions'] = (req) async {
      final r = StubServer.sse(req);
      StubServer.event(r, StubServer.chunk('ready', id: 'gen-3'));
      StubServer.event(r, {
        'id': 'gen-3',
        'model': openRouterPresetModel,
        'choices': [
          {'index': 0, 'delta': {}, 'finish_reason': 'stop'},
        ],
        'usage': {
          'prompt_tokens': 12,
          'completion_tokens': 1,
          'total_tokens': 13,
          'cost': 0.0000034,
        },
      });
      StubServer.event(r, '[DONE]', json: false);
      await r.close();
    };
    final result = await make().start(ask('hi')).done;
    expect(result.finish, LlmFinish.stop);
    expect(result.usage!.cost, 0.0000034);
    expect(result.usage!.totalTokens, 13);
  });

  group('the key', () {
    test('is read at call time and refused before a socket opens', () async {
      answerWith(['ok']);
      final empty = InMemorySecretStore();
      final noKey = await make(store: empty).start(ask('x')).done;
      expect(noKey.failure!.kind, LlmFailureKind.credential);
      expect(noKey.failure!.message, TransportText.noKey);
      final dev = await make(store: const NoSecretStore(devSecretsMessage))
          .start(ask('x'))
          .done;
      expect(dev.failure!.kind, LlmFailureKind.credential);
      expect(dev.failure!.message, devSecretsMessage);
      expect(stub.requests, isEmpty, reason: 'nothing was sent');
      // Entered later: the next call carries it, no rebuild needed.
      empty.write('provider:openrouter', canary);
      final ok = await make(store: empty).start(ask('x')).done;
      expect(ok.finish, LlmFinish.stop);
      expect(stub.requests.single.header('authorization'), 'Bearer $canary');
    });

    test('needs no origin binding: the endpoint never moves', () async {
      answerWith(['ok']);
      final provider = make();
      expect(provider.credentialOrigin, isNull);
      expect((await provider.start(ask('x')).done).finish, LlmFinish.stop);
      expect(provider.dialect.bindsKeyToOrigin, isFalse);
    });

    test('a redirect is refused, so the key goes nowhere else', () async {
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
      final result = await make().start(ask('x')).done;
      expect(result.failure!.message, TransportText.redirected);
      expect(elsewhere.requests, isEmpty);
    });
  });

  group('the probe', () {
    test('asks /key and reports the key good, no models, no window', () async {
      stub.routes['GET /v1/key'] = (req) => StubServer.json(req, {
        'data': {'label': 'sk-or-v1-abc...xyz', 'limit': 1, 'usage': 0.2},
      });
      final info = await make().probe();
      expect(info.health, EndpointHealth.ok);
      expect(info.serverKind, 'openrouter');
      expect(info.models, isEmpty);
      expect(info.contextWindow, isNull);
      expect(info.failure, isNull);
      final sent = stub.requests.single;
      expect(sent.path, '/v1/key');
      expect(sent.header('authorization'), 'Bearer $canary');
      expect(sent.header('http-referer'), 'https://github.com/slomin/sai');
      expect(info.toString(), isNot(contains('sk-or')));
    });

    test('a spent cap is unavailable; an unlimited key is fine', () async {
      stub.routes['GET /v1/key'] = (req) => StubServer.json(req, {
        'data': {
          'label': 'sk-or-v1-abc...xyz',
          'limit': 1,
          'limit_remaining': 0,
        },
      });
      final spent = await make().probe();
      expect(spent.health, EndpointHealth.unavailable);
      expect(spent.failure!.kind, LlmFailureKind.rejected);
      expect(spent.failure!.message, TransportText.noCredit);
      expect(spent.toString(), isNot(contains('sk-or')));
      stub.routes['GET /v1/key'] = (req) => StubServer.json(req, {
        'data': {'limit': null, 'limit_remaining': null, 'usage': 3.5},
      });
      expect((await make().probe()).health, EndpointHealth.ok);
      stub.routes['GET /v1/key'] = (req) => StubServer.json(req, {
        'data': {'limit': 1, 'limit_remaining': 0.25},
      });
      expect((await make().probe()).health, EndpointHealth.ok);
    });

    test('discovery keeps the common words for a status', () async {
      // A 404 on /key is not a missing route: the probe carries no routing.
      final missing = await make().probe();
      expect(missing.health, EndpointHealth.unavailable);
      expect(missing.failure!.message, TransportText.answered(404));
    });

    test('a rejected or missing key is unavailable, in fixed words', () async {
      stub.routes['GET /v1/key'] = (req) => StubServer.json(req, {
        'error': {'code': 401, 'message': 'bad $canary'},
      }, status: 401);
      final bad = await make().probe();
      expect(bad.health, EndpointHealth.unavailable);
      expect(bad.failure!.message, TransportText.rejectedKey);
      expect(bad.toString(), isNot(contains(canary)));
      stub.requests.clear();
      final none = await make(store: InMemorySecretStore()).probe();
      expect(none.health, EndpointHealth.unavailable);
      expect(none.failure!.message, TransportText.noKey);
      expect(stub.requests, isEmpty);
    });
  });

  group('the configuration', () {
    ProviderConfig config({
      String? model = openRouterPresetModel,
      String? routing = 'deepinfra_fp8',
      String? endpoint,
      String? credential = 'provider:openrouter',
      LlmPrivacy? privacy,
    }) => ProviderConfig(
      id: 'openrouter',
      kind: 'openrouter',
      endpoint: endpoint,
      defaultModel: model,
      credential: credential,
      privacy: privacy,
      routing: routing,
    );

    test('the preset and an exact model are the two good shapes', () {
      expect(openRouterProblem(config()), isNull);
      expect(
        openRouterProblem(config(model: 'qwen/qwen3-8b', routing: 'exact')),
        isNull,
      );
      expect(
        openRouterProblem(config(routing: 'exact')),
        isNull,
        reason: 'the preset model by hand is exact routing',
      );
      expect(missingForKind(config()), isNull);
    });

    test('an absent key is named bare, a wrong value as a phrase', () {
      const router = 'naming a router or a shortcut, not one exact model';
      expect(openRouterProblem(config(model: null)), 'default_model');
      for (final bad in [
        'openrouter/auto',
        'openrouter/free',
        'openrouter/auto-beta',
        'openrouter/Auto',
        'noslash',
        '~deepseek/latest',
        'qwen/qwen3-8b:nitro',
        'qwen/qwen3-8b:NITRO',
        'qwen/qwen3-8b:online',
      ]) {
        expect(
          openRouterProblem(config(model: bad, routing: 'exact')),
          router,
          reason: bad,
        );
      }
      expect(openRouterProblem(config(routing: null)), 'routing');
      expect(
        openRouterProblem(config(routing: 'cheapest')),
        'carrying a routing word this sai does not know',
      );
      expect(
        openRouterProblem(config(model: 'qwen/qwen3-8b')),
        'routed deepinfra_fp8, which fits $openRouterPresetModel only',
      );
      expect(openRouterProblem(config(credential: null)), 'credential');
      expect(
        openRouterProblem(config(endpoint: 'https://other.example/v1')),
        'carrying an endpoint, but openrouter has a fixed one',
      );
      expect(
        openRouterProblem(config(privacy: LlmPrivacy.local)),
        'tagged local, but openrouter is a cloud provider',
      );
      expect(openRouterProblem(config(privacy: LlmPrivacy.cloud)), isNull);
      expect(missingForKind(config(routing: null)), 'routing');
      // The clients read a bare key as "missing its …" and a phrase as is.
      expect(misconfiguredNote('routing'), 'missing its routing');
      expect(misconfiguredNote(router), router);
    });

    test('model problems are said in a sentence without the id', () {
      expect(openRouterModelProblem(openRouterPresetModel), isNull);
      expect(openRouterModelProblem('qwen/qwen3-8b:free'), isNull);
      expect(
        openRouterModelProblem('meta-llama/Llama-3.3-70B-Instruct'),
        isNull,
      );
      for (final bad in [
        'openrouter/auto',
        'openrouter/free',
        'openrouter/Auto',
        'OpenRouter/auto',
        'qwen',
        '~x/y',
        'a/b:floor',
        'a/b:FLOOR',
      ]) {
        final problem = openRouterModelProblem(bad);
        expect(problem, isNotNull, reason: bad);
        expect(problem, isNot(contains(bad)), reason: 'says no id back');
      }
    });

    test('the factory builds a cloud provider on the fixed origin', () {
      final built =
          openRouterFactory(config(), secrets) as OpenAiCompatibleProvider;
      expect(built.endpoint, openRouterEndpoint);
      expect(built.origin, 'https://openrouter.ai');
      expect(built.privacy, LlmPrivacy.cloud);
      expect(built.kind, 'openrouter');
      expect(built.credential, 'provider:openrouter');
      expect(built.defaultModel, openRouterPresetModel);
      expect(built.dialect, isA<OpenRouterDialect>());
      expect(
        (built.dialect as OpenRouterDialect).routing,
        OpenRouterRouting.deepinfraFp8,
      );
      final stubbed = openRouterFactory(
        config(),
        secrets,
        endpoint: stub.v1,
      ) as OpenAiCompatibleProvider;
      expect(stubbed.endpoint, stub.v1);
      // The one seam moves the origin to a loopback stub and nowhere else.
      for (final elsewhere in [
        'https://other.example/v1',
        'http://10.0.0.9/v1',
      ]) {
        expect(
          () => openRouterFactory(
            config(),
            secrets,
            endpoint: Uri.parse(elsewhere),
          ),
          throwsArgumentError,
          reason: elsewhere,
        );
        expect(
          () => openRouterBuiltin(secrets, endpoint: Uri.parse(elsewhere)),
          throwsArgumentError,
          reason: elsewhere,
        );
      }
      expect(
        () => openRouterFactory(config(routing: null), secrets),
        throwsArgumentError,
      );
      expect(
        () => openRouterFactory(config(privacy: LlmPrivacy.local), secrets),
        throwsArgumentError,
      );
    });

    test('the built-in is the preset, cloud, keyed, and describable', () {
      final builtin = openRouterBuiltin(secrets);
      expect(builtin.id, 'openrouter');
      expect(builtin.defaultModel, openRouterPresetModel);
      expect(builtin.privacy, LlmPrivacy.cloud);
      expect(builtin.takesKey, isTrue);
      expect(builtin.endpoint, openRouterEndpoint);
      final entry = configFor(builtin)!;
      expect(entry.toJson(), {
        'id': 'openrouter',
        'kind': 'openrouter',
        'default_model': openRouterPresetModel,
        'credential': 'provider:openrouter',
        'privacy': 'cloud',
        'routing': 'deepinfra_fp8',
      });
      expect(openRouterProblem(entry), isNull);
      expect(builtinLlms(secrets).map((b) => b().id), contains('openrouter'));
      expect(
        (builtinLlms(secrets, openRouterEndpoint: stub.v1).last()
                as OpenAiCompatibleProvider)
            .endpoint,
        stub.v1,
      );
    });

    test(
      'configFor describes the other built-ins the way provider add does',
      () {
        final lan = configFor(
          OpenAiCompatibleProvider(
            id: 'lan',
            endpoint: Uri.parse('http://192.168.1.5:8080/v1'),
            defaultModel: 'm',
            secrets: secrets,
          ),
        )!;
        expect(lan.toJson(), {
          'id': 'lan',
          'kind': 'openai_compatible',
          'endpoint': 'http://192.168.1.5:8080/v1',
          'default_model': 'm',
          'privacy': 'local',
        });
        expect(configFor(FakeLlmProvider())!.kind, 'fake');
      },
    );
  });
}
