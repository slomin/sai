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
  _Probed(this.answer, {this.id = 'probed', this.privacy = LlmPrivacy.local});

  EndpointInfo answer;
  var probes = 0;

  @override
  final String id;
  @override
  String get displayName => id;
  @override
  final LlmPrivacy privacy;
  @override
  String get defaultModel => 'm';
  @override
  LlmCall start(LlmRequest request) => throw UnimplementedError();
  @override
  void releaseIdle() {}

  @override
  Future<void> close() async {}
  @override
  Future<EndpointInfo> probe() async {
    probes++;
    return answer;
  }
}

/// A provider whose probes answer when the test says.
final class _Slow implements LlmProvider, LlmEndpointProbe {
  final answers = <Completer<EndpointInfo>>[];
  EndpointInfo? next;

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
  void releaseIdle() {}

  @override
  Future<void> close() async {}
  @override
  Future<EndpointInfo> probe() {
    final completer = Completer<EndpointInfo>();
    answers.add(completer);
    return completer.future;
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

  group('the walk over the order (#62)', () {
    const ok = EndpointInfo(health: EndpointHealth.ok);
    const down = EndpointInfo(
      health: EndpointHealth.unavailable,
      failure: LlmFailure(LlmFailureKind.unreachable, 'no'),
    );
    const loading = EndpointInfo(health: EndpointHealth.loading);

    /// A container whose order is [ids], over the given probeable
    /// providers.
    ProviderContainer walking(List<_Probed> probes, List<String> order) {
      final c = make(builtins: [for (final probe in probes) () => probe]);
      addTearDown(c.dispose);
      c.read(settingsProvider.notifier).setLlmOrder(order);
      // A client holds the connection for its life, which is what arms
      // the walk (`bootstrap.dart`, the assistant band).
      c.listen(connectionProvider, (_, _) {});
      return c;
    }

    test(
      'stops at the first that answers; what is behind it is not asked',
      () async {
        final head = _Probed(ok, id: 'head');
        final tail = _Probed(ok, id: 'tail');
        final c = walking([head, tail], ['head', 'tail']);
        await settle();
        expect(head.probes, 1);
        expect(tail.probes, 0, reason: 'never reached');
        expect(
          c.read(connectionProvider),
          const ConnectionStatus.ready('ready'),
        );
        expect(c.read(activeLlmProvider)?.id, 'head');
        expect(c.read(llmResolutionProvider).skipped, isEmpty);
      },
    );

    test(
      'files every answer it collects and falls through on a bad head',
      () async {
        final head = _Probed(down, id: 'head');
        final tail = _Probed(ok, id: 'tail');
        final c = walking([head, tail], ['head', 'tail']);
        await settle();
        expect(head.probes, 1);
        expect(tail.probes, 1);
        final health = c.read(providerHealthProvider);
        expect(health['head']?.health, EndpointHealth.unavailable);
        expect(health['tail']?.health, EndpointHealth.ok);
        expect(c.read(activeLlmProvider)?.id, 'tail');
        final resolution = c.read(llmResolutionProvider);
        expect(resolution.isFallback, isTrue);
        expect(resolution.skipped.single.id, 'head');
        expect(
          c.read(connectionProvider),
          const ConnectionStatus.ready('ready'),
        );
        expect(
          c.read(llmStatusProvider),
          'tail (m) — local · head unreachable',
        );
      },
    );

    test('a loading endpoint is passed over and shows amber when it is all '
        'there is', () async {
      final head = _Probed(loading, id: 'head');
      final c = walking([head], ['head']);
      await settle();
      expect(c.read(activeLlmProvider), isNull);
      expect(
        c.read(connectionProvider),
        const ConnectionStatus.attention('loading'),
      );
    });

    test(
      'nothing answering is down, with the first choice\'s own reason',
      () async {
        final head = _Probed(down, id: 'head');
        final tail = _Probed(down, id: 'tail');
        final c = walking([head, tail], ['head', 'tail']);
        await settle();
        expect(c.read(activeLlmProvider), isNull);
        expect(
          c.read(connectionProvider),
          const ConnectionStatus.down('unreachable'),
        );
        expect(c.read(llmResolutionProvider).skipped, hasLength(2));
      },
    );

    test('a recovered first choice takes over on the next tick, with no '
        'restart', () {
      fakeAsync((async) {
        final head = _Probed(down, id: 'head');
        final tail = _Probed(ok, id: 'tail');
        final c = walking([head, tail], ['head', 'tail']);
        addTearDown(c.dispose);
        async.flushMicrotasks();
        expect(c.read(activeLlmProvider)?.id, 'tail');
        head.answer = ok;
        async.elapse(Connection.probeEvery);
        async.flushMicrotasks();
        expect(head.probes, 2, reason: 'the head is asked every time');
        expect(c.read(activeLlmProvider)?.id, 'head');
        expect(c.read(llmResolutionProvider).isFallback, isFalse);
        // The tail is not asked again once the head answers.
        expect(tail.probes, 1);
      });
    });

    test('a failed call walks again at once', () async {
      final head = _Probed(down, id: 'head');
      final tail = _Probed(ok, id: 'tail');
      final c = walking([head, tail], ['head', 'tail']);
      await settle();
      expect(head.probes, 1);
      head.answer = ok;
      c
          .read(connectionProvider.notifier)
          .callFailed(const LlmFailure(LlmFailureKind.timeout, 'slow'));
      await settle();
      expect(head.probes, 2);
      expect(c.read(activeLlmProvider)?.id, 'head');
    });

    test('an entry the policy passes over is never probed', () async {
      final cloudy = _Probed(ok, id: 'cloudy', privacy: LlmPrivacy.cloud);
      final local = _Probed(ok, id: 'local');
      final c = walking([cloudy, local], ['cloudy', 'local']);
      await settle();
      expect(cloudy.probes, 0, reason: 'not a candidate while sharing is off');
      expect(local.probes, 1);
      expect(c.read(activeLlmProvider)?.id, 'local');
      c.read(settingsProvider.notifier).setShareTasksWithCloud(true);
      await settle();
      expect(cloudy.probes, 1);
      expect(c.read(activeLlmProvider)?.id, 'cloudy');
    });

    test('an unprobeable entry ends the walk and arms no timer', () {
      fakeAsync((async) {
        final tail = _Probed(ok, id: 'tail');
        final c = make(builtins: [FakeLlmProvider.new, () => tail]);
        addTearDown(c.dispose);
        c.read(settingsProvider.notifier).setLlmOrder(['fake', 'tail']);
        expect(
          c.read(connectionProvider),
          const ConnectionStatus.ready('ready'),
        );
        async.elapse(Connection.probeEvery * 3);
        expect(tail.probes, 0);
        expect(c.read(activeLlmProvider)?.id, 'fake');
      });
    });
  });

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

    test('saving the workspace neither re-probes nor flickers', () {
      fakeAsync((async) {
        final probed = _Probed(const EndpointInfo(health: EndpointHealth.ok));
        final c = make(builtins: [() => probed]);
        c.read(settingsProvider.notifier).selectLlm('probed');
        expect(c.read(connectionProvider).text, 'probing…');
        async.flushMicrotasks();
        expect(
          c.read(connectionProvider),
          const ConnectionStatus.ready('ready'),
        );
        final seen = <ConnectionStatus>[];
        c.listen(connectionProvider, (_, next) => seen.add(next));
        final status = c.read(llmStatusProvider);
        // Moving around the workspace rewrites settings (#76); the
        // connection is not about that.
        c
            .read(settingsProvider.notifier)
            .setWorkspace(const WorkspaceState(section: 'list:inbox'));
        async.flushMicrotasks();
        expect(seen, isEmpty, reason: 'no attention, no new ready');
        expect(probed.probes, 1);
        expect(c.read(llmStatusProvider), status);
        c.dispose();
      });
    });

    test("switching the selection releases the old provider's idle "
        'sockets but keeps it open (#109)', () async {
      final a = FakeLlmProvider(id: 'a');
      final b = FakeLlmProvider(id: 'b');
      final c = make(builtins: [() => a, () => b]);
      c.listen(connectionProvider, (_, _) {});
      final settings = c.read(settingsProvider.notifier);
      settings.selectLlm('a');
      c.read(connectionProvider);
      expect(a.idleReleases, 0);
      settings.selectLlm('b');
      c.read(connectionProvider);
      expect(a.idleReleases, 1);
      expect(a.isClosed, isFalse, reason: 'released, never closed');
      expect(b.idleReleases, 0);
      // Deselecting entirely releases too.
      settings.selectLlm(null);
      c.read(connectionProvider);
      expect(b.idleReleases, 1);
      // An unrelated save rebuilds with the identical instance: a no-op.
      settings.selectLlm('a');
      c.read(connectionProvider);
      settings.setWorkspace(const WorkspaceState(section: 'list:inbox'));
      c.read(connectionProvider);
      expect(a.idleReleases, 1);
      expect(b.idleReleases, 1);
    });

    test('a slow older probe cannot overwrite a newer answer', () async {
      final probed = _Slow();
      final c = make(builtins: [() => probed]);
      c.read(settingsProvider.notifier).selectLlm('probed');
      expect(c.read(connectionProvider).text, 'probing…');
      await settle();
      // The first probe is still pending; a refresh asks again and that
      // one answers first, ready.
      probed.next = const EndpointInfo(health: EndpointHealth.ok);
      c.read(connectionProvider.notifier).refresh();
      await settle();
      probed.answers[1].complete(const EndpointInfo(health: EndpointHealth.ok));
      await settle();
      expect(c.read(connectionProvider), const ConnectionStatus.ready('ready'));
      // Now the stale first probe comes back unavailable: dropped.
      probed.answers[0].complete(
        const EndpointInfo(
          health: EndpointHealth.unavailable,
          failure: LlmFailure(LlmFailureKind.unreachable, 'late'),
        ),
      );
      await settle();
      expect(c.read(connectionProvider), const ConnectionStatus.ready('ready'));
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

  group('the probed context window (#105)', () {
    test('a probe answer is retained, across selection changes too', () async {
      final probed = _Probed(
        const EndpointInfo(health: EndpointHealth.ok, contextWindow: 262144),
      );
      final c = make(builtins: [FakeLlmProvider.new, () => probed]);
      c.read(settingsProvider.notifier).selectLlm('probed');
      expect(c.read(connectionProvider).text, 'probing…');
      await settle();
      expect(c.read(contextWindowsProvider), {'probed': 262144});
      // Selecting away does not forget what the endpoint said.
      c.read(settingsProvider.notifier).selectLlm('fake');
      expect(c.read(connectionProvider).text, 'ready');
      await settle();
      expect(c.read(contextWindowsProvider), {'probed': 262144});
    });

    test('a failed probe keeps the last report; a healthy one rules', () async {
      final probed = _Probed(
        const EndpointInfo(health: EndpointHealth.ok, contextWindow: 8192),
      );
      final c = make(builtins: [() => probed]);
      c.read(settingsProvider.notifier).selectLlm('probed');
      c.read(connectionProvider);
      await settle();
      expect(c.read(contextWindowsProvider), {'probed': 8192});
      // Down: transient — what the endpoint last said stands.
      probed.answer = const EndpointInfo(
        health: EndpointHealth.unavailable,
        failure: LlmFailure(LlmFailureKind.unreachable, 'refused'),
      );
      c.read(connectionProvider.notifier).refresh();
      await settle();
      expect(c.read(contextWindowsProvider), {'probed': 8192});
      // Healthy without a window: this endpoint does not say — the old
      // report would be another backend's number, so it goes.
      probed.answer = const EndpointInfo(health: EndpointHealth.ok);
      c.read(connectionProvider.notifier).refresh();
      await settle();
      expect(c.read(contextWindowsProvider), isEmpty);
      probed.answer = const EndpointInfo(
        health: EndpointHealth.ok,
        contextWindow: 4096,
      );
      c.read(connectionProvider.notifier).refresh();
      await settle();
      expect(c.read(contextWindowsProvider), {'probed': 4096});
    });

    test('editing or removing a provider config clears its report', () async {
      final c = make();
      c.read(contextWindowsProvider.notifier).report('mine', 262144);
      c.read(contextWindowsProvider.notifier).report('other', 8192);
      c
          .read(settingsProvider.notifier)
          .upsertProvider(
            ProviderConfig(
              id: 'mine',
              kind: 'openai_compatible',
              endpoint: 'http://10.0.0.9:8080/v1',
              defaultModel: 'm',
            ),
          );
      // Re-pointed under the same id: the old backend's window would be
      // the wrong ceiling for the new one.
      expect(c.read(contextWindowsProvider), {'other': 8192});
      c.read(settingsProvider.notifier).removeProvider('other');
      expect(c.read(contextWindowsProvider), isEmpty);
    });
  });

  group('chatBudgetProvider (#105)', () {
    test('defaults without a provider, a window, or for cloud', () {
      final c = make(
        builtins: [
          FakeLlmProvider.new,
          () => FakeLlmProvider(id: 'cloudy', privacy: LlmPrivacy.cloud),
        ],
      );
      expect(c.read(chatBudgetProvider), same(defaultContextBudget));
      c.read(settingsProvider.notifier).selectLlm('fake');
      expect(c.read(chatBudgetProvider), same(defaultContextBudget));
      // A window on record helps a cloud selection not at all: the
      // compact context has no use for it.
      c.read(contextWindowsProvider.notifier).report('cloudy', 100000);
      c.read(settingsProvider.notifier).selectLlm('cloudy');
      expect(c.read(chatBudgetProvider), same(defaultContextBudget));
    });

    test('a local provider with a reported window gets it, reserve kept', () {
      final c = make();
      c.read(settingsProvider.notifier).selectLlm('fake');
      c.read(contextWindowsProvider.notifier).report('fake', 262144);
      final budget = c.read(chatBudgetProvider);
      expect(budget.maxTokens, 262144);
      expect(budget.replyReserve, defaultContextBudget.replyReserve);
    });

    test('reading the budget never probes', () {
      final probed = _Probed(
        const EndpointInfo(health: EndpointHealth.ok, contextWindow: 262144),
      );
      final c = make(builtins: [() => probed]);
      c.read(settingsProvider.notifier).selectLlm('probed');
      expect(c.read(chatBudgetProvider), same(defaultContextBudget));
      expect(probed.probes, 0);
    });
  });
}
