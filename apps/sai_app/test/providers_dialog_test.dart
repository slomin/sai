import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/commands.dart';
import 'package:sai_app/settings/providers_page.dart';
import 'package:sai_app/settings/settings_screen.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';
import 'stub_server.dart';

void main() {
  const canary = 'sk-canary-a1b2c3d4e5f60718293a4b5c';

  final lan = ProviderConfig(
    id: 'lan',
    kind: 'fake',
    defaultModel: 'qwen',
    credential: 'provider:lan',
  );

  /// Settings › Providers: the page the dialog of #29 became (#40).
  Future<void> open(WidgetTester tester, {String app = 'sai'}) async {
    menuItem(menuDelegate.menus, [app, 'Settings…']).onSelected!();
    await tester.pump();
    await tester.tap(find.byKey(settingsNavKey(SettingsSection.providers)));
    await tester.pump();
    expect(find.byType(ProvidersPage), findsOneWidget);
  }

  /// Escape leaves Settings, page and all.
  Future<void> close(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();
  }

  Future<void> select(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(providerRowKey(id)));
    await tester.pump();
  }

  /// The row's Use button.
  Finder use(String id) => find.ancestor(
    of: find.descendant(
      of: find.byKey(providerRowKey(id)),
      matching: find.text('Use'),
    ),
    matching: find.byType(TextButton),
  );

  /// Scrolls [finder] into view, then taps it: the OpenRouter block (#24)
  /// pushes the key field below the 800 px test window.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();
  }

  /// Every Text on screen, for a failure message.
  String screen() => find
      .byType(Text)
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .whereType<String>()
      .join(' | ');

  /// Pumps under a real event loop until [ready] holds — the stub server
  /// and the archive are real I/O.
  Future<void> until(
    WidgetTester tester,
    bool Function() ready, {
    Duration timeout = const Duration(seconds: 10),
  }) => tester.runAsync(() async {
    final deadline = DateTime.now().add(timeout);
    while (!ready()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out — ${screen()}');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
    }
  });

  testWidgets('lists every provider; a keyless one shows no key field', (
    tester,
  ) async {
    await pumpApp(tester);
    await open(tester);
    expect(find.byKey(providerRowKey('fake')), findsOneWidget);
    expect(find.byKey(apiKeyFieldKey), findsNothing);
    expect(find.text('Use'), findsOneWidget);
    expect(
      tester.widget<TextButton>(use('fake')).onPressed,
      isNotNull,
      reason: 'nothing is active yet, so the fake can be made so',
    );
    await close(tester);
    expect(find.byType(ProvidersPage), findsNothing);
  });

  testWidgets('Use switches the active provider in one click', (tester) async {
    final container = await pumpApp(tester);
    container.read(settingsProvider.notifier).upsertProvider(lan);
    await tester.pump();
    expect(find.text(noProviderStatus), findsOneWidget);
    await open(tester);
    expect(find.byKey(providerRowKey('lan')), findsOneWidget);
    await tester.tap(use('lan'));
    await tester.pump();
    expect(container.read(settingsProvider).llm, 'lan');
    expect(container.read(llmStatusProvider), 'lan (qwen) — local · no key');
    expect(find.text('lan (qwen) — local · no key'), findsWidgets);
    expect(
      tester.widget<TextButton>(use('lan')).onPressed,
      isNull,
      reason: 'already active',
    );
  });

  testWidgets('saving stores the key in the secret store, masked', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    final settings = container.read(settingsProvider.notifier);
    settings.upsertProvider(lan);
    settings.selectLlm('lan');
    await tester.pump();
    expect(find.textContaining('· no key'), findsWidgets);

    await open(tester);
    expect(find.text('No key stored yet.'), findsOneWidget);
    final field = tester.widget<TextField>(find.byKey(apiKeyFieldKey));
    expect(field.obscureText, isTrue);
    expect(field.enableSuggestions, isFalse);
    expect(field.autocorrect, isFalse);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNull,
      reason: 'nothing to save yet',
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Remove'))
          .onPressed,
      isNull,
      reason: 'nothing to remove yet',
    );

    await tester.enterText(find.byKey(apiKeyFieldKey), ' $canary ');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.byType(ProvidersPage), findsOneWidget, reason: 'stays open');
    expect(find.text('A key is stored in the Keychain.'), findsOneWidget);

    final secrets = container.read(secretStoreProvider) as InMemorySecretStore;
    expect(secrets.read('provider:lan'), canary, reason: 'trimmed');
    expect(
      container.read(credentialStatusProvider('lan')),
      CredentialStatus.set,
    );
    expect(find.text('key for lan saved'), findsOneWidget);
    expect(find.textContaining('· no key'), findsNothing);

    // Nowhere on disk, nowhere on screen.
    final root = container.read(archiveRootProvider);
    for (final line in archiveLines(root)) {
      expect(line, isNot(contains(canary)));
    }
    expect(
      container.read(settingsFileProvider).readAsStringSync(),
      isNot(contains(canary)),
    );
    expect(find.textContaining(canary), findsNothing);
  });

  testWidgets('the dev copy holds no credentials (#95)', (tester) async {
    final container = await pumpApp(tester, identity: SaiIdentity.dev);
    final settings = container.read(settingsProvider.notifier);
    // With an endpoint, so the row has a Test button to disable too.
    settings.upsertProvider(
      ProviderConfig(
        id: 'lan',
        kind: 'fake',
        endpoint: 'http://127.0.0.1:1/v1',
        defaultModel: 'qwen',
        credential: 'provider:lan',
      ),
    );
    settings.selectLlm('lan');
    await tester.pump();
    expect(find.textContaining('· no credentials in dev'), findsWidgets);
    await open(tester, app: 'sai dev');
    expect(
      find.text(
        'The dev copy holds no credentials. Use the stable app for this '
        'provider.',
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(find.byKey(apiKeyFieldKey)).enabled,
      isFalse,
    );
    await tester.enterText(find.byKey(apiKeyFieldKey), 'sk-x');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNull,
    );
    expect(
      container.read(credentialStatusProvider('lan')),
      CredentialStatus.absent,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Test'))
          .onPressed,
      isNull,
    );
    // The fake still works in dev.
    settings.selectLlm('fake');
    await tester.pump();
    expect(find.textContaining('fake (fake-1) — local'), findsWidgets);
  });

  testWidgets('remove deletes the key and says so', (tester) async {
    final container = await pumpApp(tester);
    container.read(settingsProvider.notifier).upsertProvider(lan);
    container.read(credentialsProvider.notifier).set('lan', canary);
    await tester.pump();

    await open(tester);
    await select(tester, 'lan');
    expect(find.text('A key is stored in the Keychain.'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pump();
    expect(
      container.read(credentialStatusProvider('lan')),
      CredentialStatus.missing,
    );
    expect(find.text('key for lan removed'), findsOneWidget);
    expect(find.text('No key stored yet.'), findsOneWidget);
  });

  testWidgets('closing with text typed changes nothing', (tester) async {
    final container = await pumpApp(tester);
    container.read(settingsProvider.notifier).upsertProvider(lan);
    await tester.pump();
    await open(tester);
    await select(tester, 'lan');
    await tester.enterText(find.byKey(apiKeyFieldKey), canary);
    await close(tester);
    expect(find.byType(ProvidersPage), findsNothing);
    expect(
      container.read(credentialStatusProvider('lan')),
      CredentialStatus.missing,
    );
  });

  testWidgets('the active provider is selected first; rows switch', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    final settings = container.read(settingsProvider.notifier);
    settings.upsertProvider(ProviderConfig(id: 'local', kind: 'fake'));
    settings.upsertProvider(
      ProviderConfig(id: 'a', kind: 'fake', credential: 'provider:a'),
    );
    settings.upsertProvider(lan);
    settings.selectLlm('lan');
    await tester.pump();
    await open(tester);
    expect(
      find.byKey(apiKeyFieldKey),
      findsOneWidget,
      reason: 'lan takes a key',
    );
    await select(tester, 'local');
    expect(find.byKey(apiKeyFieldKey), findsNothing, reason: 'local does not');
    await select(tester, 'a');
    expect(find.byKey(apiKeyFieldKey), findsOneWidget);
  });

  testWidgets('a misconfigured provider is listed but cannot be used', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    container
        .read(settingsProvider.notifier)
        .upsertProvider(ProviderConfig(id: 'bare', kind: 'openai_compatible'));
    await tester.pump();
    await open(tester);
    expect(find.text('missing its endpoint'), findsOneWidget);
    expect(tester.widget<TextButton>(use('bare')).onPressed, isNull);
  });

  group('the privacy switch (#27)', () {
    final cloudy = ProviderConfig(
      id: 'cloudy',
      kind: 'fake',
      privacy: LlmPrivacy.cloud,
    );

    testWidgets('reflects and writes the setting', (tester) async {
      final container = await pumpApp(tester);
      await open(tester);
      expect(
        tester.widget<SwitchListTile>(find.byKey(shareTasksSwitchKey)).value,
        isFalse,
      );
      expect(
        find.text('Cloud providers answer without the task list.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(shareTasksSwitchKey));
      await tester.pump();
      expect(container.read(settingsProvider).shareTasksWithCloud, isTrue);
      expect(
        tester.widget<SwitchListTile>(find.byKey(shareTasksSwitchKey)).value,
        isTrue,
      );
      expect(find.text('cloud sharing on'), findsOneWidget);
      expect(
        container.read(settingsFileProvider).readAsStringSync(),
        contains('"share_tasks_with_cloud":true'),
      );
      await tester.tap(find.byKey(shareTasksSwitchKey));
      await tester.pump();
      expect(container.read(settingsProvider).shareTasksWithCloud, isFalse);
      expect(find.text('cloud sharing off'), findsOneWidget);
    });

    testWidgets('Use on a cloud provider warns while sharing is off', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      container.read(settingsProvider.notifier).upsertProvider(cloudy);
      await tester.pump();
      await open(tester);
      expect(find.text('fake-1 — cloud'), findsOneWidget, reason: 'the tag');
      await tester.tap(use('cloudy'));
      await tester.pump();
      const warning =
          "cloud provider 'cloudy' will not see your tasks until sharing is on";
      expect(container.read(noticeProvider), warning);
      expect(
        container.read(llmStatusProvider),
        'cloudy (fake-1) — cloud · tasks withheld',
      );
      expect(
        find.text('cloudy (fake-1) — cloud · tasks withheld'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(shareTasksSwitchKey));
      await tester.pump();
      expect(container.read(llmStatusProvider), 'cloudy (fake-1) — cloud');
      expect(find.textContaining('tasks withheld'), findsNothing);
      await tester.tap(find.byKey(shareTasksSwitchKey));
      await tester.pump();
      expect(container.read(noticeProvider), warning, reason: 'off again');
    });

    testWidgets('Test on a cloud provider records the decision', (
      tester,
    ) async {
      final container = await pumpApp(tester);
      final settings = container.read(settingsProvider.notifier);
      settings.upsertProvider(
        ProviderConfig(
          id: 'cloudy',
          kind: 'fake',
          endpoint: 'http://127.0.0.1:9',
          privacy: LlmPrivacy.cloud,
        ),
      );
      settings.selectLlm('cloudy');
      await tester.pump();
      await open(tester);
      await tester.tap(find.text('Test'));
      // The fake runs on zero-length timers: fake-async pumps drive it,
      // and the archive writes in between are real I/O.
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
        if (find.textContaining('tokens/s').evaluate().isNotEmpty) break;
      }
      expect(find.textContaining('tokens/s'), findsOneWidget, reason: screen());
      final lines = archiveLines(container.read(archiveRootProvider))
          .where((l) => l.contains('"policy.') || l.contains('"provider.'))
          .toList();
      expect(lines, hasLength(4));
      expect(lines[0], contains('"policy.decision"'));
      expect(lines[0], contains('"task_context":"none"'));
      expect(lines[0], contains('"share_tasks":false'));
      expect(lines[1], contains('"provider.request"'));
      expect(lines[1], contains('"refs"'));
    });
  });

  group('against a stub endpoint', () {
    late StubServer stub;

    // flutter_test answers every HTTP request with a 400 unless told
    // otherwise; these tests talk to a real loopback stub.
    HttpOverrides? blocked;
    setUp(() async {
      blocked = HttpOverrides.current;
      HttpOverrides.global = null;
      stub = await StubServer.start();
    });
    tearDown(() async {
      await stub.close();
      HttpOverrides.global = blocked;
    });

    Future<ProviderContainer> setUpLocal(WidgetTester tester) async {
      final container = await pumpApp(tester);
      final settings = container.read(settingsProvider.notifier);
      settings.upsertProvider(
        ProviderConfig(
          id: 'local',
          kind: 'openai_compatible',
          endpoint: stub.v1,
          defaultModel: 'qwen',
        ),
      );
      settings.selectLlm('local');
      await tester.pump();
      await open(tester);
      return container;
    }

    /// Closes the provider's HTTP client so its keep-alive timer does not
    /// outlive the test.
    Future<void> release(WidgetTester tester, ProviderContainer c) async {
      await c.read(llmRegistryProvider)['local']!.close();
      await tester.pump();
    }

    testWidgets('refresh shows health, models and context', (tester) async {
      final container = await setUpLocal(tester);
      await until(tester, () => find.text('asking…').evaluate().isEmpty);
      expect(
        find.text('ok · 2 models · context unavailable'),
        findsOneWidget,
        reason:
            'a generic /v1 server says nothing about its context — '
            '${screen()}',
      );
      expect(stub.requests, contains('GET /v1/models'));
      final before = stub.requests.length;
      await tester.tap(find.text('Refresh'));
      await until(tester, () => stub.requests.length > before);
      await until(tester, () => find.text('asking…').evaluate().isEmpty);
      expect(find.text('ok · 2 models · context unavailable'), findsOneWidget);
      await release(tester, container);
    });

    testWidgets('OpenRouter ships inactive with a key field, the preset and '
        'an exact model (#24)', (tester) async {
      final store = InMemorySecretStore();
      final endpoint = Uri.parse(stub.v1);
      final container = await pumpApp(
        tester,
        secrets: store,
        builtins: [
          FakeLlmProvider.new,
          () => openRouterBuiltin(store, endpoint: endpoint),
        ],
        openRouterEndpoint: endpoint,
      );
      final settingsFile = container.read(settingsFileProvider);
      await open(tester);
      expect(find.byKey(providerRowKey('openrouter')), findsOneWidget);
      expect(container.read(settingsProvider).llm, isNull);
      expect(container.read(settingsProvider).provider('openrouter'), isNull);
      await select(tester, 'openrouter');
      // Unconfigured, it still takes a key and says which model it pins.
      expect(find.byKey(apiKeyFieldKey), findsOneWidget);
      expect(find.text('No key stored yet.'), findsOneWidget);
      expect(
        find.text(
          '$openRouterPresetModel — cloud · pinned to DeepInfra fp8 · no key',
        ),
        findsOneWidget,
        reason: screen(),
      );
      expect(
        tester.widget<ListTile>(find.byKey(openRouterPresetKey)).selected,
        isTrue,
      );
      expect(
        tester.widget<ListTile>(find.byKey(openRouterExactKey)).selected,
        isFalse,
      );
      expect(
        tester.widget<FilledButton>(find.byKey(openRouterApplyKey)).onPressed,
        isNull,
        reason: 'nothing typed yet',
      );
      // The probe is OpenRouter's key check, over the fixed transport.
      await until(tester, () => find.text('asking…').evaluate().isEmpty);
      expect(
        find.text('unavailable: no key stored for this endpoint'),
        findsOneWidget,
        reason: screen(),
      );
      expect(stub.requests, isNot(contains('GET /v1/key')));

      // Saving a key configures the built-in as shipped, then stores it.
      await tester.ensureVisible(find.byKey(apiKeyFieldKey));
      await tester.enterText(find.byKey(apiKeyFieldKey), canary);
      await tester.pump();
      await tapVisible(tester, find.text('Save'));
      expect(store.read('provider:openrouter'), canary);
      expect(
        container.read(settingsProvider).provider('openrouter')!.toJson(),
        {
          'id': 'openrouter',
          'kind': 'openrouter',
          'default_model': openRouterPresetModel,
          'credential': 'provider:openrouter',
          'privacy': 'cloud',
          'routing': 'deepinfra_fp8',
        },
      );
      expect(find.text('A key is stored in the Keychain.'), findsOneWidget);
      expect(
        find.textContaining('revoke the key at openrouter.ai'),
        findsOneWidget,
      );
      await tester.tap(find.text('Refresh'));
      await until(tester, () => stub.requests.contains('GET /v1/key'));
      await until(tester, () => find.text('asking…').evaluate().isEmpty);
      expect(
        find.text('ok · openrouter · no models listed · context unavailable'),
        findsOneWidget,
        reason: screen(),
      );
      expect(settingsFile.readAsStringSync(), isNot(contains(canary)));
      expect(screen(), isNot(contains(canary)));

      // A router id is refused and nothing changes; an exact id is stored
      // as exact routing, and the built provider follows.
      await tester.ensureVisible(find.byKey(openRouterModelFieldKey));
      await tester.enterText(
        find.byKey(openRouterModelFieldKey),
        'openrouter/auto',
      );
      await tester.pump();
      await tapVisible(tester, find.byKey(openRouterApplyKey));
      expect(
        container.read(settingsProvider).provider('openrouter')!.defaultModel,
        openRouterPresetModel,
      );
      expect(screen(), contains('routers that pick the model'));
      await tester.ensureVisible(find.byKey(openRouterModelFieldKey));
      await tester.enterText(
        find.byKey(openRouterModelFieldKey),
        'qwen/qwen3-8b',
      );
      await tester.pump();
      await tapVisible(tester, find.byKey(openRouterApplyKey));
      final exact = container.read(settingsProvider).provider('openrouter')!;
      expect(exact.defaultModel, 'qwen/qwen3-8b');
      expect(exact.routing, 'exact');
      expect(exact.credential, 'provider:openrouter');
      expect(
        tester.widget<ListTile>(find.byKey(openRouterExactKey)).selected,
        isTrue,
      );
      expect(
        find.text('qwen/qwen3-8b — cloud · exact model · key set'),
        findsOneWidget,
        reason: screen(),
      );
      final built =
          container.read(llmRegistryProvider)['openrouter']!
              as OpenAiCompatibleProvider;
      expect(built.defaultModel, 'qwen/qwen3-8b');
      expect(built.privacy, LlmPrivacy.cloud);
      expect(built.origin, stub.origin, reason: 'the fixed origin, stubbed');
      expect(openRouterRoutingOf(built), OpenRouterRouting.exact);

      // Back to the recommended preset in one tap.
      await tapVisible(tester, find.byKey(openRouterPresetKey));
      final preset = container.read(settingsProvider).provider('openrouter')!;
      expect(preset.defaultModel, openRouterPresetModel);
      expect(preset.routing, 'deepinfra_fp8');
      expect(
        tester.widget<ListTile>(find.byKey(openRouterPresetKey)).onTap,
        isNull,
        reason: 'already the preset',
      );

      // Remove drops the Keychain item and leaves the entry.
      await tapVisible(tester, find.text('Remove'));
      expect(store.accounts, isEmpty);
      expect(
        container.read(settingsProvider).provider('openrouter'),
        isNotNull,
      );
      expect(find.text('No key stored yet.'), findsOneWidget);
      expect(settingsFile.readAsStringSync(), isNot(contains(canary)));
      for (final line in archiveLines(container.read(archiveRootProvider))) {
        expect(line, isNot(contains(canary)));
      }
      await container.read(llmRegistryProvider)['openrouter']!.close();
      await tester.pump();
    });

    testWidgets('a refused OpenRouter entry keeps its block and is repaired '
        'from it (#24)', (tester) async {
      final store = InMemorySecretStore();
      final endpoint = Uri.parse(stub.v1);
      final container = await pumpApp(
        tester,
        secrets: store,
        builtins: [
          FakeLlmProvider.new,
          () => openRouterBuiltin(store, endpoint: endpoint),
        ],
        openRouterEndpoint: endpoint,
      );
      store.write('provider:openrouter', canary);
      // As a hand edit or an older sai would leave it: an endpoint, a
      // local tag, a routing word this sai does not know.
      container
          .read(settingsProvider.notifier)
          .upsertProvider(
            ProviderConfig(
              id: 'openrouter',
              kind: 'openrouter',
              endpoint: 'https://other.example/v1',
              defaultModel: 'qwen/qwen3-8b',
              credential: 'provider:openrouter',
              privacy: LlmPrivacy.local,
              routing: 'cheapest',
            ),
          );
      await tester.pump();
      expect(
        container.read(llmRegistryProvider),
        isNot(contains('openrouter')),
      );
      await open(tester);
      await select(tester, 'openrouter');
      expect(
        find.text('carrying an endpoint, but openrouter has a fixed one'),
        findsOneWidget,
        reason: screen(),
      );
      // The block and the revocation note are there for the entry itself.
      expect(find.byKey(openRouterPresetKey), findsOneWidget);
      expect(
        tester.widget<ListTile>(find.byKey(openRouterPresetKey)).selected,
        isFalse,
      );
      expect(
        tester.widget<ListTile>(find.byKey(openRouterExactKey)).selected,
        isFalse,
      );
      expect(find.text('A key is stored in the Keychain.'), findsOneWidget);
      expect(
        find.textContaining('revoke the key at openrouter.ai'),
        findsOneWidget,
      );
      // One tap on the preset rewrites the whole shape.
      await tapVisible(tester, find.byKey(openRouterPresetKey));
      final fixed = container.read(settingsProvider).provider('openrouter')!;
      expect(fixed.toJson(), {
        'id': 'openrouter',
        'kind': 'openrouter',
        'default_model': openRouterPresetModel,
        'credential': 'provider:openrouter',
        'privacy': 'cloud',
        'routing': 'deepinfra_fp8',
      });
      final built =
          container.read(llmRegistryProvider)['openrouter']!
              as OpenAiCompatibleProvider;
      expect(built.origin, stub.origin);
      expect(
        tester.widget<ListTile>(find.byKey(openRouterPresetKey)).selected,
        isTrue,
      );
      expect(screen(), isNot(contains(canary)));
      await built.close();
      await tester.pump();
    });

    testWidgets('the dev copy shows OpenRouter but holds no key (#95, #24)', (
      tester,
    ) async {
      const store = NoSecretStore(devSecretsMessage);
      final endpoint = Uri.parse(stub.v1);
      final container = await pumpApp(
        tester,
        identity: SaiIdentity.dev,
        secrets: store,
        builtins: [
          FakeLlmProvider.new,
          () => openRouterBuiltin(store, endpoint: endpoint),
        ],
        openRouterEndpoint: endpoint,
      );
      await open(tester, app: 'sai dev');
      await select(tester, 'openrouter');
      expect(
        find.text(
          '$openRouterPresetModel — cloud · pinned to DeepInfra fp8 · no credentials in dev',
        ),
        findsOneWidget,
        reason: screen(),
      );
      expect(
        tester.widget<TextField>(find.byKey(apiKeyFieldKey)).enabled,
        isFalse,
      );
      expect(
        find.textContaining('The dev copy holds no credentials'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Test'))
            .onPressed,
        isNull,
      );
      // The model choice is still the person's: it needs no key.
      await tester.ensureVisible(find.byKey(openRouterModelFieldKey));
      await tester.enterText(
        find.byKey(openRouterModelFieldKey),
        'qwen/qwen3-8b',
      );
      await tester.pump();
      await tapVisible(tester, find.byKey(openRouterApplyKey));
      expect(
        container.read(settingsProvider).provider('openrouter')!.routing,
        'exact',
      );
      expect(stub.requests, isNot(contains('GET /v1/key')));
      await container.read(llmRegistryProvider)['openrouter']!.close();
      await tester.pump();
    });

    testWidgets('a built-in endpoint can be refreshed and tested (#23)', (
      tester,
    ) async {
      stub.words = ['ready'];
      final container = await pumpApp(
        tester,
        builtins: [
          FakeLlmProvider.new,
          () => OpenAiCompatibleProvider(
            id: 'lan',
            endpoint: Uri.parse(stub.v1),
            defaultModel: 'qwen',
            secrets: InMemorySecretStore(),
          ),
        ],
      );
      await open(tester);
      await tester.tap(find.byKey(providerRowKey('lan')));
      await tester.pump();
      await until(tester, () => find.text('asking…').evaluate().isEmpty);
      expect(find.text('ok · 2 models · context unavailable'), findsOneWidget);
      await tester.tap(find.text('Test'));
      await until(
        tester,
        () => find.textContaining('tokens/s').evaluate().isNotEmpty,
      );
      expect(find.text('ready'), findsOneWidget);
      expect(
        archiveLines(container.read(archiveRootProvider))
            .where((l) => l.contains('"provider.')),
        hasLength(3),
      );
      await container.read(llmRegistryProvider)['lan']!.close();
      await tester.pump();
    });

    testWidgets('Test streams the fixed prompt through the recorder', (
      tester,
    ) async {
      stub.words = ['rea', 'dy'];
      final container = await setUpLocal(tester);
      await until(tester, () => find.text('asking…').evaluate().isEmpty);
      await tester.tap(find.text('Test'));
      await until(
        tester,
        () => find.textContaining('tokens/s').evaluate().isNotEmpty,
      );
      expect(find.text('ready'), findsOneWidget);
      expect(find.text('stop · 33.3 tokens/s'), findsOneWidget);
      final lines = archiveLines(container.read(archiveRootProvider))
          .where((l) => l.contains('"provider.'))
          .toList();
      expect(lines, hasLength(3));
      expect(lines[0], contains(providerTestPrompt));
      expect(lines[1], contains('"provider.response"'));
      expect(lines[2], contains('"tokens_per_second":33.3'));
      expect(lines[2], contains('"finish":"stop"'));
      await release(tester, container);
    });

    testWidgets('a failing endpoint is named by origin, kind and message', (
      tester,
    ) async {
      stub.chatStatus = 500;
      final container = await setUpLocal(tester);
      await until(tester, () => find.text('asking…').evaluate().isEmpty);
      await tester.tap(find.text('Test'));
      await until(
        tester,
        () => find.textContaining('failed:').evaluate().isNotEmpty,
      );
      expect(
        find.text(
          'failed: rejected — the endpoint answered 500 (${stub.origin})',
        ),
        findsOneWidget,
      );
      final lines = archiveLines(container.read(archiveRootProvider))
          .where((l) => l.contains('"provider.failure"'))
          .toList();
      expect(lines, hasLength(1));
      expect(lines.single, contains('"endpoint":"${stub.origin}"'));
      await release(tester, container);
    });

    testWidgets('Cancel test stops a slow stream', (tester) async {
      stub.words = List.filled(200, 'x ');
      final container = await setUpLocal(tester);
      await until(tester, () => find.text('asking…').evaluate().isEmpty);
      await tester.tap(find.text('Test'));
      await until(tester, () => find.text('Cancel test').evaluate().isNotEmpty);
      await until(
        tester,
        () => find.textContaining('x x').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Cancel test'));
      await until(
        tester,
        () =>
            find.text('cancelled · tokens/s unavailable').evaluate().isNotEmpty,
      );
      expect(find.text('Test'), findsOneWidget);
      await release(tester, container);
    });
  });
}
