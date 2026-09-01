import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

import '../stub_server.dart';

void main() {
  late Directory tmp;
  late StubServer stub;
  late InMemorySecretStore secrets;
  const listed = ['gpt-5.6-luna', 'gpt-5.6-sol'];

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('sai_openai_catalogue');
    stub = await StubServer.start();
    stub.routes['GET /v1/models'] = (req) => StubServer.json(req, {
      'object': 'list',
      'data': [
        {'id': 'gpt-5.6-sol', 'object': 'model'},
        {'id': 'gpt-5.6-luna', 'object': 'model'},
      ],
    });
    secrets = InMemorySecretStore();
  });

  tearDown(() async {
    await stub.close();
    tmp.deleteSync(recursive: true);
  });

  ProviderContainer make() => ProviderContainer.test(
    overrides: [
      archiveRootProvider.overrideWithValue(Directory('${tmp.path}/archive')),
      settingsFileProvider.overrideWithValue(File('${tmp.path}/settings.json')),
      eventSourceProvider.overrideWithValue('sai/test'),
      secretStoreProvider.overrideWithValue(secrets),
      builtinLlmsProvider.overrideWithValue([FakeLlmProvider.new]),
      defaultLlmIdProvider.overrideWithValue(null),
      openAiEndpointProvider.overrideWithValue(stub.v1),
    ],
  );

  test('is read on demand, once, kept for the session, forgotten with the '
      'key', () async {
    final container = make();
    addTearDown(container.dispose);
    container
        .read(settingsProvider.notifier)
        .upsertProvider(
          ProviderConfig(
            id: 'openai',
            kind: openAiKind,
            defaultModel: 'gpt-5.6-sol',
            credential: 'provider:openai',
          ),
        );
    final catalogue = container.read(openAiCatalogueProvider.notifier);
    expect(container.read(openAiCatalogueProvider).attempted, isFalse);
    expect(stub.requests, isEmpty, reason: 'nothing asks on build');
    // No key yet: the reading fails before a socket.
    await catalogue.load('openai');
    var state = container.read(openAiCatalogueProvider);
    expect(state.models, isNull);
    expect(state.failure!.kind, LlmFailureKind.credential);
    expect(stub.requests, isEmpty);
    // A key stored forgets that; the next load reads.
    container.read(credentialsProvider.notifier).set('openai', 'sk-canary-1');
    expect(container.read(openAiCatalogueProvider).attempted, isFalse);
    await catalogue.load('openai');
    state = container.read(openAiCatalogueProvider);
    expect(state.models, listed);
    expect(state.failure, isNull);
    expect(stub.requests.map((r) => r.path), ['/v1/models']);
    expect(stub.requests.single.header('authorization'), 'Bearer sk-canary-1');
    // Loaded is loaded; refresh asks again; a failed refresh keeps the list.
    await catalogue.load('openai');
    expect(stub.requests, hasLength(1));
    stub.routes['GET /v1/models'] = (req) => StubServer.json(req, {
      'error': {'message': 'down'},
    }, status: 503);
    await catalogue.refresh('openai');
    state = container.read(openAiCatalogueProvider);
    expect(state.models, listed);
    expect(state.failure!.message, 'the endpoint answered 503');
    // Nothing of it on disk.
    for (final f in tmp.listSync(recursive: true).whereType<File>()) {
      final text = f.readAsStringSync();
      expect(text, isNot(contains('gpt-5.6-luna')), reason: f.path);
      expect(text, isNot(contains('sk-canary')), reason: f.path);
    }
    // Removing the key forgets the list.
    container.read(credentialsProvider.notifier).clear('openai');
    expect(container.read(openAiCatalogueProvider).attempted, isFalse);
  });

  test('another kind\'s id reads nothing', () async {
    final container = make();
    addTearDown(container.dispose);
    await container.read(openAiCatalogueProvider.notifier).load('fake');
    expect(container.read(openAiCatalogueProvider).attempted, isFalse);
    expect(stub.requests, isEmpty);
  });

  test('matches rank starts-with before contains, nothing for nothing', () {
    const models = [
      'gpt-5.6-luna',
      'gpt-5.6-sol',
      'o4-mini',
      'text-embedding-3',
    ];
    expect(openAiCatalogueMatches(models, ''), isEmpty);
    expect(openAiCatalogueMatches(models, 'GPT'), [
      'gpt-5.6-luna',
      'gpt-5.6-sol',
    ]);
    expect(openAiCatalogueMatches(models, 'mini'), ['o4-mini']);
    expect(openAiCatalogueMatches(models, 'sol'), ['gpt-5.6-sol']);
    expect(openAiCatalogueMatches(models, 'gpt', limit: 1), ['gpt-5.6-luna']);
  });
}
