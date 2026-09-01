import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:sai_core/src/llm/openai_compatible/policy.dart';
import 'package:test/test.dart';

import 'llm/stub_server.dart';

/// The promise ADR 0006 and ADR 0008 make, checked from the outside: a
/// credential enters through the secret store, a provider that holds it
/// fails in every way a provider can, and afterwards the key is in no
/// byte sai wrote — not the archive, not the settings file, not a
/// quarantine file, not stdout — and in no message a client would show.
void main() {
  /// High-entropy, prefixed like a real key so the settings guard would
  /// also catch it, and long enough that no clipping hides it.
  const canary = 'sk-canary-7f3a9c1e5b2d4f6a8c0e1b3d5f7a9c2e4b6d8f0a';

  late Directory tmp;
  late InMemorySecretStore secrets;
  late ProviderContainer container;
  final printed = StringBuffer();

  setUp(() {
    printed.clear();
    tmp = Directory.systemTemp.createTempSync('sai_no_secrets_test');
    secrets = InMemorySecretStore();
    container = ProviderContainer.test(
      overrides: [
        archiveRootProvider.overrideWithValue(Directory('${tmp.path}/archive')),
        settingsFileProvider.overrideWithValue(
          File('${tmp.path}/settings.json'),
        ),
        eventSourceProvider.overrideWithValue('sai/test'),
        secretStoreProvider.overrideWithValue(secrets),
      ],
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  /// Every byte of every file under the temp directory, so a check does
  /// not depend on knowing where a leak could go.
  Map<String, List<int>> allBytes() => {
    for (final f in tmp.listSync(recursive: true).whereType<File>())
      f.path.substring(tmp.path.length + 1): f.readAsBytesSync(),
  };

  void expectNoCanary(Map<String, List<int>> files) {
    final needle = utf8.encode(canary);
    for (final e in files.entries) {
      expect(
        _contains(e.value, needle),
        isFalse,
        reason: '${e.key} holds the canary',
      );
    }
    expect(printed.toString(), isNot(contains(canary)), reason: 'stdout');
  }

  /// Runs [body] with `print` captured.
  Future<T> capturing<T>(Future<T> Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, line) => printed.writeln(line),
    ),
  );

  test('a credential enters, every failure path runs, nothing leaks', () async {
    final results = <LlmResult>[];
    await capturing(() async {
      final settings = container.read(settingsProvider.notifier);
      settings.upsertProvider(
        ProviderConfig(
          id: 'lan',
          kind: 'fake',
          endpoint: 'https://lan.example/v1',
          defaultModel: 'qwen',
          credential: 'provider:lan',
        ),
      );
      settings.selectLlm('lan');
      container.read(credentialsProvider.notifier).set('lan', canary);
      expect(
        container.read(credentialStatusProvider('lan')),
        CredentialStatus.set,
      );
      expect(secrets.read('provider:lan'), canary);

      final recorder = await container.read(llmRecorderProvider.future);
      final request = LlmRequest(
        messages: [const LlmMessage(LlmRole.user, 'hello')],
      );
      // A well-behaved transport fails with fixed messages that name the
      // endpoint and the status, never a header — #22's contract. The
      // recorder's own catch paths, though, see raw exceptions, and a
      // raw exception from a transport can quote anything: those two
      // carry the key here, and the recorder must not copy them.
      final providers = <LlmProvider>[
        FakeLlmProvider(
          id: 'lan',
          failWith: const LlmFailure(
            LlmFailureKind.rejected,
            'the backend rejected the request',
            endpoint: 'https://lan.example/v1',
            status: 401,
          ),
        ),
        FakeLlmProvider(
          id: 'lan',
          failWith: const LlmFailure(
            LlmFailureKind.timeout,
            'no first byte within the deadline',
            endpoint: 'https://lan.example/v1',
          ),
        ),
        FakeLlmProvider(
          id: 'lan',
          failWith: const LlmFailure(
            LlmFailureKind.protocol,
            'the backend redirected to another origin',
            endpoint: 'https://lan.example/v1',
          ),
        ),
        _ThrowingProvider(Exception('connect failed: Bearer $canary')),
        _ErroringStreamProvider(StateError('chunk: $canary')),
      ];
      for (final provider in providers) {
        final call = await recorder.start(provider, request);
        results.add(await call.done);
      }
      // A cancelled call, and a successful one, for completeness.
      final slow = FakeLlmProvider(id: 'lan', delta: const Duration(hours: 1));
      final cancelled = await recorder.start(slow, request);
      cancelled.cancel();
      results.add(await cancelled.done);
      final ok = await recorder.start(
        container.read(activeLlmProvider)!,
        request,
      );
      results.add(await ok.done);
      print('status: ${container.read(llmStatusProvider)}');
      for (final r in results) {
        print('result: $r');
      }
    });

    expect(results.map((r) => r.finish), [
      LlmFinish.failed,
      LlmFinish.failed,
      LlmFinish.failed,
      LlmFinish.failed,
      LlmFinish.failed,
      LlmFinish.cancelled,
      LlmFinish.stop,
    ]);

    final files = allBytes();
    final events = files.keys.where((k) => k.startsWith('archive/events/'));
    expect(events, isNotEmpty);
    expect(files.keys, contains('settings.json'));
    expect(files.keys.where((k) => k.contains('.bad-')), isEmpty);
    // The archive did record everything: seven calls, three lines each,
    // five of them failures — the key is in none of it.
    final lines = [
      for (final k in events)
        ...utf8.decode(files[k]!).split('\n').where((l) => l.isNotEmpty),
    ];
    expect(lines, hasLength(21));
    expect(lines.where((l) => l.contains('"provider.failure"')), hasLength(5));
    expectNoCanary(files);
    for (final r in results) {
      expect(r.toString(), isNot(contains(canary)));
    }
    expect(container.read(llmStatusProvider), 'lan (qwen) — local');
    // And the key is still where it belongs.
    expect(secrets.read('provider:lan'), canary);
  });

  test('the HTTP provider fails every way it can and the key goes only to '
      'its origin', () async {
    final stub = await StubServer.start();
    final elsewhere = await StubServer.start();
    addTearDown(stub.close);
    addTearDown(elsewhere.close);
    elsewhere.routes['POST /v1/chat/completions'] = (req) =>
        StubServer.stream(req, ['leaked']);
    const deadlines = OpenAiDeadlines(
      firstResponse: Duration(milliseconds: 300),
      interToken: Duration(milliseconds: 300),
    );
    final results = <LlmResult>[];
    await capturing(() async {
      final settings = container.read(settingsProvider.notifier);
      settings.upsertProvider(
        ProviderConfig(
          id: 'lan',
          kind: 'openai_compatible',
          endpoint: stub.v1.toString(),
          defaultModel: 'qwen',
          credential: 'provider:lan',
        ),
      );
      settings.selectLlm('lan');
      container.read(credentialsProvider.notifier).set('lan', canary);
      final config = container.read(settingsProvider).provider('lan')!;
      expect(config.keyBound, isTrue);
      OpenAiCompatibleProvider provider() => OpenAiCompatibleProvider(
        id: 'lan',
        endpoint: stub.v1,
        defaultModel: 'qwen',
        secrets: secrets,
        credential: 'provider:lan',
        credentialOrigin: config.credentialOrigin,
        deadlines: deadlines,
      );
      final recorder = await container.read(llmRecorderProvider.future);
      final request = LlmRequest(
        messages: [const LlmMessage(LlmRole.user, 'hello')],
      );
      Future<void> run() async {
        final call = await recorder.start(provider(), request);
        results.add(await call.done);
      }

      // 401 quoting the key back, a redirect elsewhere, a stall, a body
      // that is not a stream, an unreadable chunk — then cancel and success.
      stub.routes['POST /v1/chat/completions'] = (req) =>
          StubServer.json(req, {'error': 'bad key $canary'}, status: 401);
      await run();
      stub.routes['POST /v1/chat/completions'] = (req) async {
        req.response
          ..statusCode = 307
          ..headers.set(
            'location',
            '${elsewhere.origin}/v1/chat/completions?k=$canary',
          );
        await req.response.close();
      };
      await run();
      stub.routes['POST /v1/chat/completions'] = (req) async {
        final r = StubServer.sse(req);
        StubServer.event(r, StubServer.chunk('partial '));
        await Future<void>.delayed(const Duration(seconds: 2));
        await r.close();
      };
      await run();
      stub.routes['POST /v1/chat/completions'] = (req) =>
          StubServer.json(req, {'echo': canary});
      await run();
      stub.routes['POST /v1/chat/completions'] = (req) async {
        final r = StubServer.sse(req);
        StubServer.event(r, 'garbage $canary', json: false);
        await r.close();
      };
      await run();
      stub.routes['POST /v1/chat/completions'] = (req) => StubServer.stream(
        req,
        ['slow', 'er'],
        gap: const Duration(seconds: 2),
      );
      final cancelled = await recorder.start(provider(), request);
      await cancelled.deltas.first;
      cancelled.cancel();
      results.add(await cancelled.done);
      stub.routes['POST /v1/chat/completions'] = (req) =>
          StubServer.stream(req, ['ready']);
      final ok = await recorder.start(
        container.read(activeLlmProvider)!,
        request,
      );
      results.add(await ok.done);
      for (final r in results) {
        print('result: $r');
      }
    });
    expect(results.map((r) => r.finish), [
      LlmFinish.failed,
      LlmFinish.failed,
      LlmFinish.failed,
      LlmFinish.failed,
      LlmFinish.failed,
      LlmFinish.cancelled,
      LlmFinish.stop,
    ]);
    expect(results.last.text, 'ready');
    expect(
      elsewhere.requests,
      isEmpty,
      reason: 'nothing followed the redirect',
    );
    // The key went out exactly as a bearer token, to the configured origin
    // and nowhere else — not in a URL, not in a body.
    for (final sent in stub.requests) {
      expect(sent.header('authorization'), 'Bearer $canary');
      expect(sent.path, '/v1/chat/completions');
      expect(sent.body, isNot(contains(canary)));
    }
    final files = allBytes();
    final lines = [
      for (final k in files.keys.where((k) => k.startsWith('archive/events/')))
        ...utf8.decode(files[k]!).split('\n').where((l) => l.isNotEmpty),
    ];
    expect(lines, hasLength(21));
    expect(lines.where((l) => l.contains('"provider.failure"')), hasLength(5));
    for (final line in lines.where((l) => l.contains('"endpoint"'))) {
      expect(line, contains('"endpoint":"${stub.origin}"'));
    }
    expectNoCanary(files);
    for (final r in results) {
      expect(r.toString(), isNot(contains(canary)));
    }
  });

  test('the OpenRouter built-in takes a key the same way and leaks nothing '
      '(#24)', () async {
    final stub = await StubServer.start();
    addTearDown(stub.close);
    final container = ProviderContainer.test(
      overrides: [
        archiveRootProvider.overrideWithValue(Directory('${tmp.path}/archive')),
        settingsFileProvider.overrideWithValue(
          File('${tmp.path}/settings.json'),
        ),
        eventSourceProvider.overrideWithValue('sai/test'),
        secretStoreProvider.overrideWithValue(secrets),
        openRouterEndpointProvider.overrideWithValue(stub.v1),
      ],
    );
    final results = <LlmResult>[];
    await capturing(() async {
      container.read(settingsProvider.notifier).selectLlm('openrouter');
      // The built-in is configured as it ships by the first key stored.
      container.read(credentialsProvider.notifier).set('openrouter', canary);
      final recorder = await container.read(llmRecorderProvider.future);
      final request = LlmRequest(
        messages: [const LlmMessage(LlmRole.user, 'hello')],
        reasoningEffort: ReasoningEffort.none,
      );
      Future<void> run() async {
        final call = await recorder.start(
          container.read(activeLlmProvider)!,
          request,
        );
        results.add(await call.done);
      }

      // A 401 and a 404 that quote the key, then success.
      stub.routes['POST /v1/chat/completions'] = (req) => StubServer.json(req, {
        'error': {'code': 401, 'message': 'bad key $canary'},
      }, status: 401);
      await run();
      stub.routes['POST /v1/chat/completions'] = (req) => StubServer.json(req, {
        'error': {'code': 404, 'message': 'no route for $canary'},
      }, status: 404);
      await run();
      stub.routes['POST /v1/chat/completions'] = (req) =>
          StubServer.stream(req, ['ready'], id: 'gen-1');
      await run();
      for (final r in results) {
        print('result: $r');
      }
    });
    expect(results.map((r) => r.finish), [
      LlmFinish.failed,
      LlmFinish.failed,
      LlmFinish.stop,
    ]);
    expect(results[1].failure!.message, 'no endpoint matched the pinned route');
    for (final sent in stub.requests) {
      expect(sent.header('authorization'), 'Bearer $canary');
      expect(sent.path, '/v1/chat/completions');
      expect(sent.body, isNot(contains(canary)));
      expect(sent.body, contains('"only":["deepinfra"]'));
    }
    final files = allBytes();
    final lines = [
      for (final k in files.keys.where((k) => k.startsWith('archive/events/')))
        ...utf8.decode(files[k]!).split('\n').where((l) => l.isNotEmpty),
    ];
    // A cloud call is four lines (ADR 0010): the decision and the three.
    expect(lines.where((l) => l.contains('"policy.decision"')), hasLength(3));
    expect(lines.where((l) => l.contains('"provider.failure"')), hasLength(2));
    for (final line in lines.where((l) => l.contains('"endpoint"'))) {
      expect(line, contains('"endpoint":"${stub.origin}"'));
    }
    expect(
      utf8.decode(files['settings.json']!),
      allOf(contains('"routing":"deepinfra_fp8"'), isNot(contains('sk-'))),
    );
    expectNoCanary(files);
    for (final r in results) {
      expect(r.toString(), isNot(contains(canary)));
    }
  });

  test(
    'the openai kind takes a key the same way and leaks nothing (#26)',
    () async {
      final stub = await StubServer.start();
      addTearDown(stub.close);
      final container = ProviderContainer.test(
        overrides: [
          archiveRootProvider.overrideWithValue(
            Directory('${tmp.path}/archive'),
          ),
          settingsFileProvider.overrideWithValue(
            File('${tmp.path}/settings.json'),
          ),
          eventSourceProvider.overrideWithValue('sai/test'),
          secretStoreProvider.overrideWithValue(secrets),
          openAiEndpointProvider.overrideWithValue(stub.v1),
        ],
      );
      final results = <LlmResult>[];
      List<String>? catalogue;
      LlmFailure? catalogueFailure;
      await capturing(() async {
        final settings = container.read(settingsProvider.notifier);
        settings.upsertProvider(
          ProviderConfig(
            id: 'openai',
            kind: openAiKind,
            defaultModel: 'gpt-5.6-sol',
            credential: 'provider:openai',
            reasoningEffort: 'high',
          ),
        );
        settings.selectLlm('openai');
        container.read(credentialsProvider.notifier).set('openai', canary);
        final recorder = await container.read(llmRecorderProvider.future);
        final provider =
            container.read(activeLlmProvider)! as OpenAiResponsesProvider;
        final request = LlmRequest(
          messages: [const LlmMessage(LlmRole.user, 'hello')],
          reasoningEffort: container.read(requestedEffortProvider),
        );
        Future<void> run() async {
          final call = await recorder.start(provider, request);
          results.add(await call.done);
        }

        // A 401 quoting the key, an effort refusal quoting it, a failed
        // response quoting it, a tool call, a model list quoting it, then
        // success.
        stub.routes['POST /v1/responses'] = (req) => StubServer.json(req, {
          'error': {'code': 'invalid_api_key', 'message': 'bad key $canary'},
        }, status: 401);
        await run();
        stub.routes['POST /v1/responses'] = (req) => StubServer.json(req, {
          'error': {
            'code': 'unsupported_value',
            'param': 'reasoning.effort',
            'message': 'no high for $canary',
          },
        }, status: 400);
        await run();
        stub.routes['POST /v1/responses'] = (req) async {
          final response = StubServer.sse(req);
          StubServer.event(response, {
            'type': 'response.failed',
            'response': {
              'error': {'code': 'server_error', 'message': canary},
            },
          });
          await response.close();
        };
        await run();
        stub.routes['POST /v1/responses'] = (req) async {
          final response = StubServer.sse(req);
          StubServer.event(response, {
            'type': 'response.output_item.added',
            'item': {'type': 'function_call', 'name': canary},
          });
          await response.close();
        };
        await run();
        stub.routes['GET /v1/models'] = (req) => StubServer.json(req, {
          'data': [
            {'id': 'gpt-5.6-sol', 'owned_by': canary},
          ],
        });
        final list = await fetchOpenAiCatalogue(provider);
        catalogue = list.models;
        catalogueFailure = list.failure;
        stub.routes['POST /v1/responses'] = (req) async {
          final response = StubServer.sse(req);
          StubServer.event(response, {
            'type': 'response.output_text.delta',
            'delta': 'ready',
          });
          StubServer.event(response, {
            'type': 'response.completed',
            'response': {
              'id': 'resp_9',
              'model': 'gpt-5.6-sol',
              'usage': {
                'input_tokens': 1,
                'output_tokens': 1,
                'total_tokens': 2,
              },
            },
          });
          await response.close();
        };
        await run();
        for (final r in results) {
          print('result: $r');
        }
        print('catalogue: $catalogue $catalogueFailure');
      });
      expect(results.map((r) => r.finish), [
        LlmFinish.failed,
        LlmFinish.failed,
        LlmFinish.failed,
        LlmFinish.failed,
        LlmFinish.stop,
      ]);
      expect(results[1].failure!.message, TransportText.effortRefused);
      expect(results[3].failure!.message, TransportText.toolCalled);
      expect(catalogue, ['gpt-5.6-sol']);
      expect(catalogueFailure, isNull);
      for (final sent in stub.requests) {
        expect(sent.header('authorization'), 'Bearer $canary');
        expect(sent.path, anyOf('/v1/responses', '/v1/models'));
        expect(sent.body, isNot(contains(canary)));
        if (sent.path == '/v1/responses') {
          expect(sent.body, contains('"store":false'));
          expect(sent.body, contains('"reasoning":{"effort":"high"}'));
        }
      }
      final files = allBytes();
      final lines = [
        for (final k in files.keys.where(
          (k) => k.startsWith('archive/events/'),
        ))
          ...utf8.decode(files[k]!).split('\n').where((l) => l.isNotEmpty),
      ];
      // A cloud call is four lines (ADR 0010): the decision and the three.
      expect(lines.where((l) => l.contains('"policy.decision"')), hasLength(5));
      expect(
        lines.where((l) => l.contains('"provider.failure"')),
        hasLength(4),
      );
      for (final line in lines.where((l) => l.contains('"provider.request"'))) {
        expect(line, contains('"reasoning_effort":"high"'));
      }
      for (final line in lines.where((l) => l.contains('"endpoint"'))) {
        expect(line, contains('"endpoint":"${stub.origin}"'));
      }
      expect(
        utf8.decode(files['settings.json']!),
        allOf(contains('"kind":"openai"'), isNot(contains('sk-'))),
      );
      expectNoCanary(files);
      for (final r in results) {
        expect(r.toString(), isNot(contains(canary)));
      }
    },
  );

  test('a key written into settings by hand is refused and not repeated', () {
    File('${tmp.path}/settings.json').writeAsStringSync(
      '{"version":0,"llm":null,"providers":[{"id":"lan","kind":"fake",'
      '"api_key":"$canary"}]}',
    );
    final settings = container.read(settingsProvider);
    expect(settings.problem, isNotNull);
    expect(settings.problem, contains('secret-like key'));
    expect(settings.problem, isNot(contains(canary)));
    expect(container.read(llmStatusProvider), unreadableSettingsStatus);
    // The next write starts fresh and clean.
    container.read(settingsProvider.notifier).selectLlm('fake');
    expect(
      File('${tmp.path}/settings.json').readAsStringSync(),
      '{"llm":"fake","version":0}',
    );
  });

  test('the secret store never quotes a value in an error', () {
    expect(
      () => secrets.write('bad account', canary),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.toString(),
          'text',
          isNot(contains(canary)),
        ),
      ),
    );
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// A provider whose `start` throws — the recorder's first catch path.
final class _ThrowingProvider implements LlmProvider {
  _ThrowingProvider(this.error);

  final Object error;

  @override
  String get id => 'lan';
  @override
  String get displayName => 'lan';
  @override
  LlmPrivacy get privacy => LlmPrivacy.local;
  @override
  String get defaultModel => 'qwen';

  @override
  LlmCall start(LlmRequest request) => throw error;

  @override
  void releaseIdle() {}

  @override
  Future<void> close() async {}
}

/// A provider whose deltas stream errors — the recorder's second.
final class _ErroringStreamProvider implements LlmProvider {
  _ErroringStreamProvider(this.error);

  final Object error;

  @override
  String get id => 'lan';
  @override
  String get displayName => 'lan';
  @override
  LlmPrivacy get privacy => LlmPrivacy.local;
  @override
  String get defaultModel => 'qwen';

  @override
  LlmCall start(LlmRequest request) => _ErroringCall(error, defaultModel);

  @override
  void releaseIdle() {}

  @override
  Future<void> close() async {}
}

final class _ErroringCall implements LlmCall {
  _ErroringCall(Object error, String model)
    : _done = Completer<LlmResult>(),
      _model = ModelRef(provider: 'lan', id: model) {
    final controller = StreamController<LlmDelta>();
    deltas = controller.stream;
    scheduleMicrotask(() async {
      controller.addError(error);
      await controller.close();
    });
  }

  final Completer<LlmResult> _done;
  final ModelRef _model;

  @override
  late final Stream<LlmDelta> deltas;

  @override
  Future<LlmResult> get done => _done.future;

  @override
  void cancel() {
    if (_done.isCompleted) return;
    _done.complete(
      LlmResult(text: '', finish: LlmFinish.cancelled, model: _model),
    );
  }
}
