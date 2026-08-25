import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/providers_dialog.dart';
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

  Future<void> open(WidgetTester tester) async {
    menuItem(menuDelegate.menus, ['sai', 'Providers…']).onSelected!();
    await tester.pump();
    expect(find.byType(ProvidersDialog), findsOneWidget);
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
    await tester.tap(find.text('Close'));
    await tester.pump();
    expect(find.byType(ProvidersDialog), findsNothing);
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
    expect(find.byType(ProvidersDialog), findsOneWidget, reason: 'stays open');
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
    await tester.tap(find.text('Close'));
    await tester.pump();
    expect(find.byType(ProvidersDialog), findsNothing);
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
