import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/commands.dart';
import 'package:sai_app/reorder/drag_handle.dart';
import 'package:sai_app/settings/providers_page.dart';
import 'package:sai_app/settings/settings_screen.dart';
import 'package:sai_core/process_testing.dart';
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

  group('the preference order (#62)', () {
    ProviderConfig fake(String id) => ProviderConfig(id: id, kind: 'fake');

    Future<ProviderContainer> withOrder(
      WidgetTester tester,
      List<String> order, {
      List<ProviderConfig> configs = const [],
    }) async {
      final container = await pumpApp(tester);
      final settings = container.read(settingsProvider.notifier);
      for (final config in configs) {
        settings.upsertProvider(config);
      }
      settings.setLlmOrder(order);
      await tester.pump();
      await open(tester);
      return container;
    }

    testWidgets('the order is numbered, the rest sits below it', (
      tester,
    ) async {
      final container = await withOrder(
        tester,
        ['b', 'fake'],
        configs: [fake('a'), fake('b')],
      );
      expect(find.text('2. fake'), findsOneWidget);
      expect(find.text('1. b'), findsOneWidget);
      // Configured but not in the order: no place, no order controls.
      expect(find.text('a'), findsOneWidget);
      expect(find.byKey(providerUpKey('a')), findsNothing);
      expect(find.byKey(providerDropKey('a')), findsNothing);
      expect(container.read(llmOrderProvider), ['b', 'fake']);
    });

    testWidgets('Use puts a row first and keeps the arranged tail', (
      tester,
    ) async {
      final container = await withOrder(
        tester,
        ['b', 'fake'],
        configs: [fake('a'), fake('b')],
      );
      expect(tester.widget<TextButton>(use('b')).onPressed, isNull);
      await tester.tap(use('fake'));
      await tester.pump();
      expect(container.read(llmOrderProvider), ['fake', 'b']);
      // A row from outside takes the head's place; the tail stands.
      await tester.tap(use('a'));
      await tester.pump();
      expect(container.read(llmOrderProvider), ['a', 'b']);
    });

    testWidgets('Move up and Move down reorder, and stop at the ends', (
      tester,
    ) async {
      final container = await withOrder(
        tester,
        ['a', 'b', 'fake'],
        configs: [fake('a'), fake('b')],
      );
      expect(
        tester.widget<IconButton>(find.byKey(providerUpKey('a'))).onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(providerDownKey('fake')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(providerDownKey('a')));
      await tester.pump();
      expect(container.read(llmOrderProvider), ['b', 'a', 'fake']);
      await tester.tap(find.byKey(providerUpKey('a')));
      await tester.pump();
      expect(container.read(llmOrderProvider), ['a', 'b', 'fake']);
    });

    testWidgets('the add button puts a row at the end of the order', (
      tester,
    ) async {
      final container = await withOrder(
        tester,
        ['fake'],
        configs: [fake('a'), fake('b')],
      );
      // Use makes a first choice; only this one lengthens the order.
      expect(find.byKey(providerAddKey('fake')), findsNothing);
      await tester.tap(find.byKey(providerAddKey('a')));
      await tester.pump();
      expect(container.read(llmOrderProvider), ['fake', 'a']);
      await tester.tap(find.byKey(providerAddKey('b')));
      await tester.pump();
      expect(container.read(llmOrderProvider), ['fake', 'a', 'b']);
      expect(find.byKey(providerAddKey('a')), findsNothing);
    });

    testWidgets('the close button takes a row out of the order', (
      tester,
    ) async {
      final container = await withOrder(
        tester,
        ['a', 'fake'],
        configs: [fake('a')],
      );
      await tester.tap(find.byKey(providerDropKey('a')));
      await tester.pump();
      expect(container.read(llmOrderProvider), ['fake']);
      // Still configured, still listed — just not tried.
      expect(find.byKey(providerRowKey('a')), findsOneWidget);
      expect(find.byKey(providerDropKey('a')), findsNothing);
    });

    testWidgets('an id only the order names is still shown and removable', (
      tester,
    ) async {
      // A settings file from a build with one more provider: `ghost` is
      // in the order and nothing here can offer it. Drawn all the same,
      // or the arrows would move an entry the page never shows.
      final container = await pumpApp(tester);
      container.read(settingsProvider.notifier).setLlmOrder(['ghost', 'fake']);
      await tester.pump();
      await open(tester);
      expect(find.text('1. ghost'), findsOneWidget);
      expect(find.textContaining('not available in this build'), findsWidgets);
      // Moving the shown head moves the shown head, not a hidden entry.
      await tester.tap(find.byKey(providerDownKey('ghost')));
      await tester.pump();
      expect(container.read(llmOrderProvider), ['fake', 'ghost']);
      await tester.tap(find.byKey(providerDropKey('ghost')));
      await tester.pump();
      expect(container.read(llmOrderProvider), ['fake']);
      expect(find.byKey(providerRowKey('ghost')), findsNothing);
    });

    testWidgets('a handle drags a row to another place', (tester) async {
      final container = await withOrder(
        tester,
        ['a', 'b', 'fake'],
        configs: [fake('a'), fake('b')],
      );
      await dragRow(
        tester,
        handle: find.byKey(dragHandleKey('a')),
        source: find.byKey(providerRowKey('a')),
        target: find.byKey(providerRowKey('b')),
      );
      await tester.pump();
      expect(container.read(llmOrderProvider), ['b', 'a', 'fake']);
    });

    testWidgets('each row says what the order made of it', (tester) async {
      final container = await withOrder(
        tester,
        ['keyed', 'fake'],
        configs: [
          ProviderConfig(
            id: 'keyed',
            kind: 'fake',
            credential: 'provider:keyed',
          ),
        ],
      );
      expect(find.textContaining('· no key'), findsWidgets);
      // The second entry answered, and the check mark is on it.
      expect(container.read(activeLlmProvider)?.id, 'fake');
      expect(find.textContaining('local · ready'), findsOneWidget);
      container.read(credentialsProvider.notifier).set('keyed', 'k');
      await tester.pump();
      expect(container.read(activeLlmProvider)?.id, 'keyed');
      expect(find.textContaining('local · not asked'), findsOneWidget);
    });
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
        find.text('Cloud providers are passed over until this is on.'),
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
          "cloud provider 'cloudy' will not be used until sharing is on";
      expect(container.read(noticeProvider), warning);
      expect(
        container.read(llmStatusProvider),
        'cloudy (fake-1) — cloud · cloud not allowed',
      );
      expect(
        find.text('cloudy (fake-1) — cloud · cloud not allowed'),
        findsOneWidget,
      );
      // Passed over entirely while the switch is off (#62).
      expect(container.read(activeLlmProvider), isNull);
      await tester.tap(find.byKey(shareTasksSwitchKey));
      await tester.pump();
      expect(container.read(llmStatusProvider), 'cloudy (fake-1) — cloud');
      expect(container.read(activeLlmProvider)?.id, 'cloudy');
      expect(find.textContaining('cloud not allowed'), findsNothing);
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

  group('the OpenAI API kind (#26)', () {
    late StubServer stub;
    HttpOverrides? blocked;
    setUp(() async {
      blocked = HttpOverrides.current;
      HttpOverrides.global = null;
      stub = await StubServer.start();
      stub.openAiModels = ['gpt-5.6-luna', 'gpt-5.6-sol', 'o4-mini'];
    });
    tearDown(() async {
      await stub.close();
      HttpOverrides.global = blocked;
    });

    Future<ProviderContainer> setUpOpenAi(WidgetTester tester) async {
      final container = await pumpApp(
        tester,
        openAiEndpoint: Uri.parse(stub.v1),
      );
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
      await tester.pump();
      await open(tester);
      await select(tester, 'openai');
      return container;
    }

    Map<String, Object?> entry(ProviderContainer container) =>
        container.read(settingsProvider).provider('openai')!.toJson();

    testWidgets('names its billing, keeps its own effort, lists models '
        'once a key is stored, and applies an exact id', (tester) async {
      final container = await setUpOpenAi(tester);
      expect(
        find.textContaining(
          'gpt-5.6-sol — cloud · OpenAI API, billed separately',
        ),
        findsOneWidget,
      );
      expect(find.text('OpenAI API — billed separately'), findsOneWidget);
      // The global switch is not this kind's: its effort menu is.
      expect(find.byKey(reasoningSwitchKey), findsNothing);
      expect(find.byKey(openAiEffortKey), findsOneWidget);
      expect(find.text('Model default'), findsOneWidget);
      expect(find.text('Save an OpenAI key to list models'), findsOneWidget);
      expect(find.byKey(apiKeyFieldKey), findsOneWidget);
      // A key: the list is read, once, and offered as one types.
      await tester.enterText(find.byKey(apiKeyFieldKey), canary);
      await tapVisible(tester, find.widgetWithText(FilledButton, 'Save'));
      await until(
        tester,
        () => container.read(openAiCatalogueProvider).models != null,
      );
      await tester.pump();
      expect(
        find.textContaining('3 models this key can reach — guidance only'),
        findsOneWidget,
      );
      expect(stub.requests.where((r) => r == 'GET /v1/models'), hasLength(1));
      await tester.enterText(find.byKey(openAiModelFieldKey), 'luna');
      await tester.pump();
      expect(find.text('gpt-5.6-luna'), findsOneWidget);
      await tapVisible(tester, find.text('gpt-5.6-luna'));
      await tapVisible(tester, find.byKey(openAiModelApplyKey));
      expect(entry(container)['default_model'], 'gpt-5.6-luna');
      expect(entry(container), isNot(contains('reasoning_effort')));
      // A typed id that is not listed still applies: guidance, not a gate.
      await tester.enterText(find.byKey(openAiModelFieldKey), 'gpt-6-preview');
      await tapVisible(tester, find.byKey(openAiModelApplyKey));
      expect(entry(container)['default_model'], 'gpt-6-preview');
      // The effort is its own choice; the model stays.
      await tapVisible(tester, find.byKey(openAiEffortKey));
      await tester.pump();
      await tester.tap(find.text('xhigh').last);
      await tester.pump();
      expect(entry(container)['reasoning_effort'], 'xhigh');
      expect(entry(container)['default_model'], 'gpt-6-preview');
      expect(find.textContaining('depends on the model'), findsOneWidget);
      // Nothing of the key or the list on disk.
      final settings = File(container.read(settingsFileProvider).path)
          .readAsStringSync();
      expect(settings, isNot(contains(canary)));
      expect(settings, isNot(contains('o4-mini')));
      await close(tester);
      await container.read(llmRegistryProvider)['openai']!.close();
    });

    testWidgets('Test runs the exact pair; an unsupported effort fails once '
        'and changes nothing', (tester) async {
      final container = await setUpOpenAi(tester);
      container.read(credentialsProvider.notifier).set('openai', canary);
      container
          .read(settingsProvider.notifier)
          .upsertProvider(
            container
                .read(settingsProvider)
                .provider('openai')!
                .copyWith(reasoningEffort: () => 'xhigh'),
          );
      await tester.pump();
      stub.responsesStatus = 400;
      stub.responsesParam = 'reasoning.effort';
      await tapVisible(tester, find.widgetWithText(TextButton, 'Test'));
      await until(
        tester,
        () => find
            .textContaining('the model does not take this reasoning effort')
            .evaluate()
            .isNotEmpty,
      );
      expect(stub.responsesBodies, hasLength(1), reason: 'no retry');
      expect(stub.responsesBodies.single['reasoning'], {'effort': 'xhigh'});
      expect(stub.responsesBodies.single['store'], isFalse);
      expect(stub.responsesBodies.single, isNot(contains('temperature')));
      expect(entry(container)['reasoning_effort'], 'xhigh');
      expect(entry(container)['default_model'], 'gpt-5.6-sol');
      // The pair the model takes streams.
      stub.responsesStatus = 200;
      stub.words = ['ready', '.'];
      await tapVisible(tester, find.widgetWithText(TextButton, 'Test'));
      await until(
        tester,
        () => find.textContaining('stop ·').evaluate().isNotEmpty,
      );
      expect(find.text('ready.'), findsOneWidget);
      final lines = archiveLines(container.read(archiveRootProvider));
      expect(
        lines.where((l) => l.contains('"provider.request"')),
        hasLength(2),
      );
      for (final l in lines.where((l) => l.contains('"provider.request"'))) {
        expect(l, contains('"reasoning_effort":"xhigh"'));
      }
      expect(lines.join(), isNot(contains(canary)));
      await close(tester);
      await container.read(llmRegistryProvider)['openai']!.close();
    });
  });

  group('the ChatGPT subscription kind (#26)', () {
    late FakeAppServer server;
    late Directory sidecarDir;

    setUp(() {
      server = FakeAppServer();
      sidecarDir = Directory.systemTemp.createTempSync('sai_app_sidecar');
      File('${sidecarDir.path}/codex-app-server').writeAsStringSync('stub');
    });
    tearDown(() => sidecarDir.deleteSync(recursive: true));

    Future<ProviderContainer> setUpChatGpt(
      WidgetTester tester, {
      SaiIdentity identity = SaiIdentity.stable,
      String? model = 'gpt-5.6-sol',
    }) async {
      final container = await pumpApp(
        tester,
        identity: identity,
        processRunner: server.runner,
        sidecar: identity.isDev
            ? null
            : SidecarLocator('${sidecarDir.path}/codex-app-server'),
      );
      container
          .read(settingsProvider.notifier)
          .upsertProvider(
            ProviderConfig(
              id: 'chatgpt',
              kind: chatGptKind,
              defaultModel: model,
            ),
          );
      await tester.pump();
      await open(tester, app: identity.isDev ? 'sai dev' : 'sai');
      await select(tester, 'chatgpt');
      return container;
    }

    Map<String, Object?> entry(ProviderContainer container) =>
        container.read(settingsProvider).provider('chatgpt')!.toJson();

    testWidgets('shows the account, the live models and the model\'s '
        'efforts; model and effort are two choices', (tester) async {
      final container = await setUpChatGpt(tester);
      expect(
        find.textContaining('gpt-5.6-sol — cloud · ChatGPT subscription'),
        findsOneWidget,
      );
      expect(find.byKey(reasoningSwitchKey), findsNothing);
      await until(tester, () => container.read(chatGptProvider).signedIn);
      await tester.pump();
      expect(
        find.textContaining('Signed in as person@example.com · pro plan'),
        findsOneWidget,
      );
      expect(find.byKey(chatGptSignOutKey), findsOneWidget);
      expect(find.byKey(chatGptSignInKey), findsNothing);
      expect(find.text('GPT-5.6 Sol'), findsOneWidget);
      expect(find.text('Model default (medium)'), findsOneWidget);
      expect(find.textContaining('Plan usage: 25% used'), findsOneWidget);
      expect(find.textContaining('\$'), findsNothing, reason: 'never money');
      // The effort menu is the model's advertised list.
      await tapVisible(tester, find.byKey(chatGptEffortKey));
      await tester.pump();
      expect(find.text('xhigh'), findsOneWidget);
      await tester.tap(find.text('xhigh'));
      await tester.pump();
      expect(entry(container)['reasoning_effort'], 'xhigh');
      // Another model: the effort stays, and is judged against the new
      // model's list — Luna takes no xhigh, so it shows as unavailable.
      await tapVisible(tester, find.byKey(chatGptModelKey));
      await tester.pump();
      await tester.tap(find.text('GPT-5.6 Luna').last);
      await tester.pump();
      expect(entry(container)['default_model'], 'gpt-5.6-luna');
      expect(entry(container)['reasoning_effort'], 'xhigh');
      expect(find.text('xhigh — unavailable'), findsOneWidget);
      expect(find.byKey(chatGptEffortKey), findsOneWidget);
      // Nothing of the account on disk.
      final settings = File(container.read(settingsFileProvider).path)
          .readAsStringSync();
      expect(settings, isNot(contains('person@example.com')));
      expect(settings, isNot(contains('pro plan')));
      await close(tester);
    });

    testWidgets('a saved model the list no longer carries stays visible as '
        'unavailable', (tester) async {
      final container = await setUpChatGpt(tester, model: 'gpt-5.5-gone');
      await until(tester, () => container.read(chatGptProvider).signedIn);
      await tester.pump();
      expect(find.text('gpt-5.5-gone — unavailable'), findsOneWidget);
      expect(find.textContaining('not in the current list'), findsOneWidget);
      expect(
        entry(container)['default_model'],
        'gpt-5.5-gone',
        reason: 'never swapped',
      );
      await close(tester);
    });

    testWidgets('sign out, then sign in by device code, cancel, and browser', (
      tester,
    ) async {
      final container = await setUpChatGpt(tester);
      await until(tester, () => container.read(chatGptProvider).signedIn);
      await tester.pump();
      await tapVisible(tester, find.byKey(chatGptSignOutKey));
      await until(
        tester,
        () =>
            !container.read(chatGptProvider).signedIn &&
            !container.read(chatGptProvider).loading,
      );
      await tester.pump();
      expect(server.logouts, 1);
      expect(find.textContaining('Not signed in'), findsOneWidget);
      expect(find.byKey(chatGptSignInKey), findsOneWidget);
      expect(find.byKey(chatGptDeviceCodeKey), findsOneWidget);
      // Device code: the URL and the code shown, Cancel cancels.
      await tapVisible(tester, find.byKey(chatGptDeviceCodeKey));
      await until(
        tester,
        () => container.read(chatGptProvider).login.isDeviceCode,
      );
      await tester.pump();
      expect(
        find.textContaining(
          'Open https://auth.openai.com/codex/device and enter the code ABCD-1234',
        ),
        findsOneWidget,
      );
      await tapVisible(tester, find.byKey(chatGptCancelSignInKey));
      await until(tester, () => server.loginCancels.isNotEmpty);
      await tester.pump();
      expect(find.text(CodexText.loginCancelled), findsOneWidget);
      await tapVisible(tester, find.text('OK'));
      // Browser: without a Runner the URL is shown on the bar instead.
      await tapVisible(tester, find.byKey(chatGptSignInKey));
      await until(
        tester,
        () =>
            container.read(chatGptProvider).login.phase ==
            ChatGptLoginPhase.browser,
      );
      await tester.pump();
      expect(
        find.textContaining('Finish signing in in the browser'),
        findsOneWidget,
      );
      // No Runner behind the channel here: the URL is handed to the bar
      // instead of a browser; either way nothing was spawned.
      expect(server.logins.last, {'type': 'chatgpt'});
      // The completion lands: signed in, the list read.
      server.account = {
        'type': 'chatgpt',
        'email': 'p@example.com',
        'planType': 'plus',
      };
      server.runner.processes.single.notify('account/login/completed', {
        'loginId': 'login-2',
        'success': true,
      });
      await until(tester, () => container.read(chatGptProvider).signedIn);
      await until(
        tester,
        () =>
            container.read(chatGptProvider).login.phase ==
            ChatGptLoginPhase.idle,
      );
      await tester.pump();
      expect(
        find.textContaining('Signed in as p@example.com · plus plan'),
        findsOneWidget,
      );
      // No token anywhere on screen or disk.
      expect(screen(), isNot(contains('token')));
      await close(tester);
    });

    testWidgets('View › Set Reasoning Effort… opens the provider\'s setting', (
      tester,
    ) async {
      final container = await setUpChatGpt(tester);
      await close(tester);
      container.read(settingsProvider.notifier).selectLlm('chatgpt');
      await tester.pump();
      expect(
        menuItem(menuDelegate.menus, ['View', 'Set Reasoning Effort…']),
        isNotNull,
      );
      menuItem(menuDelegate.menus, [
        'View',
        'Set Reasoning Effort…',
      ]).onSelected!();
      await tester.pump();
      await tester.pump();
      expect(find.byType(ProvidersPage), findsOneWidget);
      expect(find.byKey(chatGptAccountKey), findsOneWidget);
      // The global switch was not flipped.
      expect(container.read(settingsProvider).reasoningOn, isFalse);
      await close(tester);
      container.read(settingsProvider.notifier).selectLlm('fake');
      await tester.pump();
      expect(
        menuItem(menuDelegate.menus, ['View', 'Enable Reasoning']),
        isNotNull,
      );
    });

    testWidgets('the dev copy runs no runtime and says so', (tester) async {
      final container = await setUpChatGpt(tester, identity: SaiIdentity.dev);
      expect(find.text(CodexText.devRefused), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(chatGptSignInKey)).onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Test'))
            .onPressed,
        isNull,
      );
      expect(container.read(appServerRuntimeProvider), isNull);
      expect(server.runner.spawns, isEmpty);
      await close(tester);
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
      await tester.tap(find.byKey(endpointRefreshKey));
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
      expect(
        find.textContaining(
          'One owner/name id from openrouter.ai/models with an endpoint that '
          'meets the privacy filters',
        ),
        findsOneWidget,
        reason: screen(),
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
      await tester.tap(find.byKey(endpointRefreshKey));
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
      // The requirement travels with the selected state (#115).
      expect(
        find.textContaining(
          'qwen/qwen3-8b — needs an endpoint that meets the privacy filters, '
          'zero retention above all',
        ),
        findsOneWidget,
        reason: screen(),
      );

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
      // An entry with no model at all shows the requirement, never "null".
      container
          .read(settingsProvider.notifier)
          .upsertProvider(
            ProviderConfig(
              id: 'openrouter',
              kind: 'openrouter',
              credential: 'provider:openrouter',
              routing: 'exact',
            ),
          );
      await tester.pump();
      expect(find.text('missing its default_model'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing, reason: screen());
      expect(
        find.textContaining('One owner/name id from openrouter.ai/models'),
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
        find.text(
          'The dev copy holds no credentials. Use the stable app for this '
          'provider.',
        ),
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
      // No credentials, no list (#112): the line says so in the key
      // row's own terms, and nothing is asked.
      expect(
        find.text(
          'The dev copy holds no credentials, so no list; use the stable app',
        ),
        findsOneWidget,
        reason: screen(),
      );
      expect(
        tester.widget<TextButton>(find.byKey(openRouterRefreshKey)).onPressed,
        isNull,
      );
      expect(stub.requests, isNot(contains('GET /v1/key')));
      expect(stub.requests, isNot(contains('GET /v1/endpoints/zdr')));
      await container.read(llmRegistryProvider)['openrouter']!.close();
      await tester.pump();
    });

    testWidgets('OpenRouter suggests zero-retention models and applies one '
        '(#112)', (tester) async {
      final store = InMemorySecretStore();
      final endpoint = Uri.parse(stub.v1);
      // Sixty more ids than the box shows at once, and the first reading
      // held back until the test lets it land.
      stub.zdrExtra = 60;
      stub.zdrGate = Completer<void>();
      final container = await pumpApp(
        tester,
        secrets: store,
        builtins: [
          FakeLlmProvider.new,
          () => openRouterBuiltin(store, endpoint: endpoint),
        ],
        openRouterEndpoint: endpoint,
      );
      int listed() =>
          stub.requests.where((r) => r == 'GET /v1/endpoints/zdr').length;
      ProviderConfig entry() =>
          container.read(settingsProvider).provider('openrouter')!;
      String fieldText() => tester
          .widget<TextField>(find.byKey(openRouterModelFieldKey))
          .controller!
          .text;
      // Which rows are highlighted, by their colour.
      List<bool> lit() => find
          .descendant(
            of: find.byKey(openRouterOptionsKey),
            matching: find.byType(Container),
          )
          .evaluate()
          .map((e) => (e.widget as Container).color != null)
          .toList();
      Future<void> type(String text) async {
        await tester.ensureVisible(find.byKey(openRouterModelFieldKey));
        await tester.enterText(find.byKey(openRouterModelFieldKey), text);
        await tester.pump();
      }

      Future<void> enter() async {
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
      }

      await open(tester);
      await select(tester, 'openrouter');
      // Without a key nothing is asked; the line says what would help.
      expect(
        find.text('Save an OpenRouter key to load models'),
        findsOneWidget,
        reason: screen(),
      );
      expect(
        tester.widget<TextButton>(find.byKey(openRouterRefreshKey)).onPressed,
        isNull,
      );
      await until(tester, () => find.text('asking…').evaluate().isEmpty);
      expect(listed(), 0);

      // A stored key starts the session's one reading …
      await tester.ensureVisible(find.byKey(apiKeyFieldKey));
      await tester.enterText(find.byKey(apiKeyFieldKey), canary);
      await tester.pump();
      await tapVisible(tester, find.text('Save'));
      await until(tester, () => listed() == 1);
      expect(find.text('Loading zero-retention models…'), findsOneWidget);
      expect(
        tester.widget<TextButton>(find.byKey(openRouterRefreshKey)).onPressed,
        isNull,
        reason: 'one reading at a time',
      );
      // … and letters typed while it is under way are answered when it
      // lands, not left without suggestions until the next keystroke.
      await type('glm');
      expect(find.byKey(openRouterOptionsKey), findsNothing);
      stub.zdrGate!.complete();
      await until(
        tester,
        () => find.text('63 models with zero retention').evaluate().isNotEmpty,
      );
      await until(
        tester,
        () => find.text('z-ai/glm-5.2:free').evaluate().isNotEmpty,
      );
      expect(listed(), 1);
      expect(container.read(openRouterCatalogueProvider).models, hasLength(63));

      // Focus alone offers nothing; a few letters narrow — deduplicated,
      // no router, sorted, ids alone.
      await type('');
      expect(find.byKey(openRouterOptionsKey), findsNothing);
      await tester.tap(find.byKey(openRouterModelFieldKey));
      await tester.pump();
      expect(find.byKey(openRouterOptionsKey), findsNothing);
      await type('a');
      expect(find.text('deepseek/deepseek-v4-flash-0731'), findsOneWidget);
      expect(find.text('qwen/qwen3-235b-a22b'), findsOneWidget);
      expect(find.text('z-ai/glm-5.2:free'), findsOneWidget);
      expect(find.text('openrouter/auto'), findsNothing);
      expect(find.text('owner/model-00'), findsNothing, reason: 'no a in it');
      expect(screen(), isNot(contains('Qwen3 235B')));
      expect(screen(), isNot(contains('GMICloud')));

      // ↓ moves the highlight; Enter takes it into the field, keeps the
      // focus and applies nothing; Enter again applies it.
      expect(lit(), [true, false, false]);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(lit(), [false, true, false]);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(lit(), [false, true, false]);
      await enter();
      expect(fieldText(), 'qwen/qwen3-235b-a22b');
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'openrouter-model',
        reason: 'taking a suggestion keeps the person in the field',
      );
      expect(entry().defaultModel, openRouterPresetModel, reason: 'not yet');
      expect(find.byKey(openRouterOptionsKey), findsNothing);
      await enter();
      expect(entry().defaultModel, 'qwen/qwen3-235b-a22b');
      expect(entry().routing, 'exact');
      // Applied and left: clicking back in opens nothing.
      expect(fieldText(), isEmpty);
      await tester.tap(find.byKey(openRouterModelFieldKey));
      await tester.pump();
      expect(find.byKey(openRouterOptionsKey), findsNothing);

      // A tapped suggestion fills the field the same way; Apply writes it.
      await type('glm');
      await tester.tap(find.text('z-ai/glm-5.2:free'));
      await tester.pump();
      expect(fieldText(), 'z-ai/glm-5.2:free');
      expect(entry().defaultModel, 'qwen/qwen3-235b-a22b', reason: 'not yet');
      await tapVisible(tester, find.byKey(openRouterApplyKey));
      expect(entry().defaultModel, 'z-ai/glm-5.2:free');

      // An id the list does not have still applies on Enter — even one a
      // listed id begins with: Escape closes the list and keeps the field.
      await type('qwen/qwen3-235b');
      expect(find.text('qwen/qwen3-235b-a22b'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(openRouterOptionsKey), findsNothing);
      expect(find.byType(ProvidersPage), findsOneWidget, reason: 'still open');
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'openrouter-model',
      );
      await enter();
      expect(entry().defaultModel, 'qwen/qwen3-235b');
      await type('qwen/qwen3-8b');
      expect(find.byKey(openRouterOptionsKey), findsNothing);
      await enter();
      expect(entry().defaultModel, 'qwen/qwen3-8b');
      expect(listed(), 1, reason: 'choosing never re-reads the list');

      // A list taller than its box follows the highlight.
      await type('owner');
      final box = tester.getRect(find.byKey(openRouterOptionsKey));
      final eighth = find.text('owner/model-08', skipOffstage: false);
      expect(
        box.contains(tester.getRect(find.text('owner/model-00')).center),
        isTrue,
      );
      if (eighth.evaluate().isNotEmpty) {
        expect(
          box.contains(tester.getRect(eighth).center),
          isFalse,
          reason: 'below the box',
        );
      }
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      expect(
        box.contains(tester.getRect(eighth).center),
        isTrue,
        reason: screen(),
      );
      expect(lit(), contains(true));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      // A failed refresh keeps the list and says why, in fixed words.
      stub.zdrStatus = 500;
      await tapVisible(tester, find.byKey(openRouterRefreshKey));
      await until(tester, () => listed() == 2);
      await until(
        tester,
        () => find
            .text(
              'Could not refresh (the endpoint answered 500); showing 63 '
              'models cached',
            )
            .evaluate()
            .isNotEmpty,
      );
      await type('glm');
      expect(find.text('z-ai/glm-5.2:free'), findsOneWidget, reason: screen());
      expect(screen(), isNot(contains(canary)));
      expect(screen(), isNot(contains('model_name')));
      expect(
        container.read(settingsFileProvider).readAsStringSync(),
        isNot(contains('Qwen3 235B')),
      );
      for (final line in archiveLines(container.read(archiveRootProvider))) {
        expect(line, isNot(contains('endpoints/zdr')));
        expect(line, isNot(contains('Qwen3 235B')));
      }

      // Removing the key forgets the list read under it.
      await tapVisible(tester, find.text('Remove'));
      expect(
        find.text('Save an OpenRouter key to load models'),
        findsOneWidget,
        reason: screen(),
      );
      await type('glm');
      expect(find.byKey(openRouterOptionsKey), findsNothing);
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
