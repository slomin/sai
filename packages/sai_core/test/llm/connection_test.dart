import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

import 'stub_server.dart';

/// A provider that answers a scripted probe, so cadence can be tested
/// under a fake clock without a socket.
final class _Probed implements LlmProvider, LlmEndpointProbe {
  _Probed(this.answer);

  EndpointInfo answer;
  var probes = 0;

  @override
  String get id => 'probed';
  @override
  String get displayName => 'probed';
  @override
  LlmPrivacy get privacy => LlmPrivacy.local;
  @override
  String get defaultModel => 'm';
  @override
  LlmCall start(LlmRequest request) => throw UnimplementedError();
  @override
  Future<void> close() async {}
  @override
  Future<EndpointInfo> probe() async {
    probes++;
    return answer;
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('sai_connection'));
  tearDown(() => tmp.deleteSync(recursive: true));

  ProviderContainer make({
    List<LlmProvider Function()> builtins = const [FakeLlmProvider.new],
    List<Override> overrides = const [],
  }) => ProviderContainer.test(
    overrides: [
      archiveRootProvider.overrideWithValue(Directory('${tmp.path}/archive')),
      settingsFileProvider.overrideWithValue(File('${tmp.path}/s.json')),
      eventSourceProvider.overrideWithValue('sai/test'),
      secretStoreProvider.overrideWithValue(InMemorySecretStore()),
      builtinLlmsProvider.overrideWithValue(builtins),
      defaultLlmIdProvider.overrideWithValue(null),
      ...overrides,
    ],
  );

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('connectionProvider (#40)', () {
    test('no provider is down; the fake is ready without a probe', () async {
      final c = make();
      expect(
        c.read(connectionProvider),
        const ConnectionStatus.down('no provider'),
      );
      c.read(settingsProvider.notifier).selectLlm('fake');
      expect(c.read(connectionProvider), const ConnectionStatus.ready('ready'));
    });

    test('a misconfigured or missing key is down, in words', () {
      final c = make();
      final settings = c.read(settingsProvider.notifier);
      settings.upsertProvider(
        ProviderConfig(id: 'half', kind: 'openai_compatible'),
      );
      settings.selectLlm('half');
      expect(c.read(connectionProvider).level, ConnectionLevel.down);
      expect(c.read(connectionProvider).text, 'misconfigured');
      settings.upsertProvider(
        ProviderConfig(
          id: 'keyed',
          kind: 'openai_compatible',
          endpoint: 'https://lan.example:8443/v1',
          defaultModel: 'm',
          credential: 'provider:keyed',
        ),
      );
      settings.selectLlm('keyed');
      expect(c.read(connectionProvider).text, 'no key');
      expect(c.read(connectionProvider).level, ConnectionLevel.down);
    });

    test(
      'a live endpoint goes probing → ready; a refused one → down',
      () async {
        final stub = await StubServer.start();
        addTearDown(stub.close);
        stub.routes['GET /v1/models'] = (req) => StubServer.json(req, {
          'data': [
            {'id': 'qwen'},
          ],
        });
        final c = make();
        final settings = c.read(settingsProvider.notifier);
        settings.upsertProvider(
          ProviderConfig(
            id: 'local',
            kind: 'openai_compatible',
            endpoint: stub.v1.toString(),
            defaultModel: 'qwen',
          ),
        );
        settings.selectLlm('local');
        expect(
          c.read(connectionProvider),
          const ConnectionStatus.attention('probing…'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(
          c.read(connectionProvider),
          const ConnectionStatus.ready('ready'),
        );
        final port = stub.port;
        await stub.close();
        settings.upsertProvider(
          ProviderConfig(
            id: 'gone',
            kind: 'openai_compatible',
            endpoint: 'http://127.0.0.1:$port/v1',
            defaultModel: 'qwen',
          ),
        );
        settings.selectLlm('gone');
        // riverpod 3 rebuilds on the next read; the probe starts then.
        expect(c.read(connectionProvider).text, 'probing…');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(c.read(connectionProvider).level, ConnectionLevel.down);
        expect(c.read(connectionProvider).text, 'unreachable');
      },
    );

    test('loading is attention; it re-probes on the timer and on refresh', () {
      fakeAsync((async) {
        final probed = _Probed(
          const EndpointInfo(health: EndpointHealth.loading),
        );
        final c = make(builtins: [() => probed]);
        c.read(settingsProvider.notifier).selectLlm('probed');
        expect(c.read(connectionProvider).text, 'probing…');
        async.flushMicrotasks();
        expect(probed.probes, 1);
        expect(
          c.read(connectionProvider),
          const ConnectionStatus.attention('loading'),
        );
        async.elapse(Connection.probeEvery);
        expect(probed.probes, 2);
        probed.answer = const EndpointInfo(health: EndpointHealth.ok);
        c.read(connectionProvider.notifier).refresh();
        async.flushMicrotasks();
        expect(probed.probes, 3);
        expect(
          c.read(connectionProvider),
          const ConnectionStatus.ready('ready'),
        );
        c.dispose();
        async.elapse(Connection.probeEvery * 2);
        expect(probed.probes, 3, reason: 'no timer after dispose');
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('a failed call turns it down without waiting for the timer', () async {
      final probed = _Probed(const EndpointInfo(health: EndpointHealth.ok));
      final c = make(builtins: [() => probed]);
      c.read(settingsProvider.notifier).selectLlm('probed');
      expect(c.read(connectionProvider).text, 'probing…');
      await settle();
      expect(c.read(connectionProvider).level, ConnectionLevel.ready);
      probed.answer = const EndpointInfo(
        health: EndpointHealth.unavailable,
        failure: LlmFailure(LlmFailureKind.unreachable, 'refused'),
      );
      c
          .read(connectionProvider.notifier)
          .callFailed(const LlmFailure(LlmFailureKind.unreachable, 'refused'));
      await settle();
      expect(
        c.read(connectionProvider),
        const ConnectionStatus.down('unreachable'),
      );
    });
  });
}
