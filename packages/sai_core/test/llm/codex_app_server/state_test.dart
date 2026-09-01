import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

import 'package:sai_core/process_testing.dart';

void main() {
  late Directory tmp;
  late FakeAppServer server;
  late File sidecar;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_chatgpt_state');
    sidecar = File(p.join(tmp.path, 'Helpers', 'codex-app-server'))
      ..createSync(recursive: true)
      ..writeAsStringSync('stub');
    server = FakeAppServer();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  ProviderContainer make({bool dev = false}) => ProviderContainer.test(
    overrides: [
      archiveRootProvider.overrideWithValue(Directory('${tmp.path}/archive')),
      settingsFileProvider.overrideWithValue(File('${tmp.path}/settings.json')),
      eventSourceProvider.overrideWithValue('sai/test'),
      secretStoreProvider.overrideWithValue(InMemorySecretStore()),
      environmentProvider.overrideWithValue({'HOME': tmp.path}),
      identityProvider.overrideWithValue(
        dev ? SaiIdentity.dev : SaiIdentity.stable,
      ),
      builtinLlmsProvider.overrideWithValue([FakeLlmProvider.new]),
      defaultLlmIdProvider.overrideWithValue(null),
      processRunnerProvider.overrideWithValue(server.runner),
      sidecarLocatorProvider.overrideWithValue(SidecarLocator(sidecar.path)),
    ],
  );

  test('the runtime is one per process, on the flavor\'s home', () async {
    final container = make();
    final runtime = container.read(appServerRuntimeProvider)!;
    expect(
      container.read(codexHomeProvider)!.path,
      p.join(
        resolveDataDir(
          environment: {'HOME': tmp.path},
          operatingSystem: Platform.operatingSystem,
        ).path,
        'codex',
      ),
    );
    expect(
      identical(container.read(appServerRuntimeProvider), runtime),
      isTrue,
    );
    // Two entries of the kind share it, and the factory builds them.
    final settings = container.read(settingsProvider.notifier);
    settings.upsertProvider(
      ProviderConfig(id: 'a', kind: chatGptKind, defaultModel: 'gpt-5.6-sol'),
    );
    settings.upsertProvider(ProviderConfig(id: 'b', kind: chatGptKind));
    final registry = container.read(llmRegistryProvider);
    final a = registry['a']! as ChatGptSubscriptionProvider;
    final b = registry['b']! as ChatGptSubscriptionProvider;
    expect(identical(a.runtime, b.runtime), isTrue);
    expect(a.hasModel, isTrue);
    expect(b.hasModel, isFalse);
    expect(container.read(misconfiguredLlmsProvider), isEmpty);
    // Disposing the container closes the runtime.
    container.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(
      server.runner.spawns,
      isEmpty,
      reason: 'nothing spawned until asked',
    );
  });

  test(
    'the dev flavor has no home, no runtime, and refuses in fixed words',
    () async {
      final container = make(dev: true);
      expect(container.read(codexHomeProvider), isNull);
      expect(container.read(appServerRuntimeProvider), isNull);
      final notifier = container.read(chatGptProvider.notifier);
      await notifier.load();
      final state = container.read(chatGptProvider);
      expect(state.failure!.kind, LlmFailureKind.credential);
      expect(state.failure!.message, CodexText.devRefused);
      expect(state.loading, isFalse);
      final error = await notifier
          .signIn(deviceCode: false)
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((error as CodexException).text, CodexText.devRefused);
      expect(server.runner.spawns, isEmpty);
      container.dispose();
    },
  );

  test('load reads the account, the models and the limits once; refresh '
      'reads again; concurrent reads join', () async {
    final container = make();
    addTearDown(container.dispose);
    final notifier = container.read(chatGptProvider.notifier);
    expect(container.read(chatGptProvider).attempted, isFalse);
    expect(server.runner.spawns, isEmpty, reason: 'nothing on build');
    final first = notifier.load();
    final second = notifier.load();
    final third = notifier.refresh();
    expect(container.read(chatGptProvider).loading, isTrue);
    await Future.wait([first, second, third]);
    final state = container.read(chatGptProvider);
    expect(state.signedIn, isTrue);
    expect(state.account!.planType, 'pro');
    expect(state.models!.map((m) => m.id), ['gpt-5.6-sol', 'gpt-5.6-luna']);
    expect(state.defaultModel!.id, 'gpt-5.6-sol');
    expect(
      state.modelNamed('gpt-5.6-luna')!.takes(const ReasoningEffort('high')),
      isTrue,
    );
    expect(state.modelNamed('gone'), isNull);
    expect(state.limits!.primary!.usedPercent, 25);
    expect(state.loading, isFalse);
    expect(state.failure, isNull);
    expect(server.accountReads, 1, reason: 'three callers, one reading');
    expect(server.modelLists, 1);
    // Loaded is loaded.
    await notifier.load();
    expect(server.accountReads, 1);
    // Refresh asks again.
    await notifier.refresh();
    expect(server.accountReads, 2);
    // Nothing of it on disk.
    for (final f in tmp.listSync(recursive: true).whereType<File>()) {
      final text = f.readAsStringSync();
      expect(text, isNot(contains('person@example.com')), reason: f.path);
      expect(text, isNot(contains('GPT-5.6 Sol')), reason: f.path);
    }
  });

  test('signed out: the account is read, no list, a fixed failure', () async {
    server.account = null;
    final container = make();
    addTearDown(container.dispose);
    await container.read(chatGptProvider.notifier).load();
    final state = container.read(chatGptProvider);
    expect(state.signedIn, isFalse);
    expect(state.account!.type, CodexAccountType.none);
    expect(state.models, isNull);
    expect(state.limits, isNull);
    expect(
      state.failure,
      isNull,
      reason: 'signed out is a state, not a failure',
    );
    expect(server.modelLists, 0);
  });

  test('a runtime that cannot start is a failure in fixed words', () async {
    server.runner.startError = const ProcessException('x', []);
    final container = make();
    addTearDown(container.dispose);
    await container.read(chatGptProvider.notifier).load();
    final state = container.read(chatGptProvider);
    expect(state.failure!.message, CodexText.startFailed);
    expect(state.account, isNull);
  });

  group('sign-in', () {
    test('browser: the URL comes back; completion re-reads; late '
        'completions of another attempt are ignored', () async {
      final container = make();
      addTearDown(container.dispose);
      final notifier = container.read(chatGptProvider.notifier);
      server.account = null;
      await notifier.load();
      expect(container.read(chatGptProvider).signedIn, isFalse);
      final login = await notifier.signIn(deviceCode: false);
      expect(login.phase, ChatGptLoginPhase.browser);
      expect(login.authUrl, startsWith('https://auth.openai.com/'));
      expect(login.loginId, 'login-1');
      expect(container.read(chatGptProvider).login.inProgress, isTrue);
      // A second sign-in while one runs is refused.
      final busy = await notifier
          .signIn(deviceCode: true)
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((busy as CodexException).text, CodexText.loginBusy);
      final process = server.runner.processes.single;
      // A stale attempt's completion changes nothing.
      process.notify('account/login/completed', {
        'loginId': 'login-0',
        'success': true,
      });
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(chatGptProvider).login.phase,
        ChatGptLoginPhase.browser,
      );
      // This attempt completes: the runtime is signed in now.
      server.account = {
        'type': 'chatgpt',
        'email': 'p@example.com',
        'planType': 'plus',
      };
      process.notify('account/login/completed', {
        'loginId': 'login-1',
        'success': true,
      });
      process.notify('account/updated', {
        'authMode': 'chatgpt',
        'planType': 'plus',
      });
      await Future<void>.delayed(Duration.zero);
      await notifier.done;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final state = container.read(chatGptProvider);
      expect(state.signedIn, isTrue);
      expect(state.account!.planType, 'plus');
      expect(state.models, isNotNull);
      expect(state.login.phase, ChatGptLoginPhase.idle);
    });

    test('device code: URL and code come back; cancel cancels', () async {
      final container = make();
      addTearDown(container.dispose);
      final notifier = container.read(chatGptProvider.notifier);
      final login = await notifier.signIn(deviceCode: true);
      expect(login.phase, ChatGptLoginPhase.deviceCode);
      expect(login.userCode, 'ABCD-1234');
      expect(login.verificationUrl, 'https://auth.openai.com/codex/device');
      await notifier.cancelSignIn();
      await Future<void>.delayed(Duration.zero);
      expect(server.loginCancels, [
        {'loginId': 'login-1'},
      ]);
      expect(
        container.read(chatGptProvider).login.phase,
        ChatGptLoginPhase.cancelled,
      );
      notifier.dismissLogin();
      expect(
        container.read(chatGptProvider).login.phase,
        ChatGptLoginPhase.idle,
      );
    });

    test(
      'a failed completion is shown as failed, and can be dismissed',
      () async {
        final container = make();
        addTearDown(container.dispose);
        final notifier = container.read(chatGptProvider.notifier);
        await notifier.signIn(deviceCode: true);
        server.runner.processes.single.notify('account/login/completed', {
          'loginId': 'login-1',
          'success': false,
          'error': 'expired sk-canary',
        });
        await Future<void>.delayed(Duration.zero);
        final state = container.read(chatGptProvider);
        expect(state.login.phase, ChatGptLoginPhase.failed);
        expect('$state', isNot(contains('sk-canary')));
        notifier.dismissLogin();
        expect(
          container.read(chatGptProvider).login.phase,
          ChatGptLoginPhase.idle,
        );
      },
    );
  });

  test('sign out clears the account, the list and the limits', () async {
    final container = make();
    addTearDown(container.dispose);
    final notifier = container.read(chatGptProvider.notifier);
    await notifier.load();
    expect(container.read(chatGptProvider).models, isNotNull);
    await notifier.signOut();
    await notifier.done;
    final state = container.read(chatGptProvider);
    expect(server.logouts, 1);
    expect(state.signedIn, isFalse);
    expect(state.models, isNull);
    expect(state.limits, isNull);
  });

  test('a rate-limit update lands without a read', () async {
    final container = make();
    addTearDown(container.dispose);
    await container.read(chatGptProvider.notifier).load();
    server.runner.processes.single.notify('account/rateLimits/updated', {
      'rateLimits': {
        'primary': {'usedPercent': 90},
      },
    });
    await Future<void>.delayed(Duration.zero);
    expect(container.read(chatGptProvider).limits!.primary!.usedPercent, 90);
    expect(server.rateLimitReads, 1);
  });

  test('forget drops what was read; the next load reads again', () async {
    final container = make();
    addTearDown(container.dispose);
    final notifier = container.read(chatGptProvider.notifier);
    await notifier.load();
    notifier.forget();
    expect(container.read(chatGptProvider).attempted, isFalse);
    await notifier.load();
    expect(server.accountReads, 2);
  });
}
