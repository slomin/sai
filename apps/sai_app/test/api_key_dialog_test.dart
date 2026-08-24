import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/api_key_dialog.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

void main() {
  const canary = 'sk-canary-a1b2c3d4e5f60718293a4b5c';

  final lan = ProviderConfig(
    id: 'lan',
    kind: 'fake',
    defaultModel: 'qwen',
    credential: 'provider:lan',
  );

  Future<void> open(WidgetTester tester) async {
    menuItem(menuDelegate.menus, ['sai', 'Provider API Key…']).onSelected!();
    await tester.pump();
    expect(find.byType(ApiKeyDialog), findsOneWidget);
  }

  testWidgets('with no keyed provider the dialog says how to add one', (
    tester,
  ) async {
    await pumpApp(tester);
    await open(tester);
    expect(find.text(noKeyedProviderText), findsOneWidget);
    expect(find.byKey(apiKeyFieldKey), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pump();
    expect(find.byType(ApiKeyDialog), findsNothing);
  });

  testWidgets('saving stores the key in the secret store, masked', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    final settings = container.read(settingsProvider.notifier);
    settings.upsertProvider(lan);
    settings.selectLlm('lan');
    await tester.pump();
    expect(find.textContaining('· no key'), findsOneWidget);

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
    expect(find.byType(ApiKeyDialog), findsNothing);

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
    expect(find.text('A key is stored in the Keychain.'), findsOneWidget);
    await tester.tap(find.text('Remove'));
    await tester.pump();
    expect(find.byType(ApiKeyDialog), findsNothing);
    expect(
      container.read(credentialStatusProvider('lan')),
      CredentialStatus.missing,
    );
    expect(find.text('key for lan removed'), findsOneWidget);
  });

  testWidgets('cancel changes nothing', (tester) async {
    final container = await pumpApp(tester);
    container.read(settingsProvider.notifier).upsertProvider(lan);
    await tester.pump();
    await open(tester);
    await tester.enterText(find.byKey(apiKeyFieldKey), canary);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(find.byType(ApiKeyDialog), findsNothing);
    expect(
      container.read(credentialStatusProvider('lan')),
      CredentialStatus.missing,
    );
  });

  testWidgets('the picker lists keyed providers, active one first', (
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
    final dialog = find.byType(ApiKeyDialog);
    expect(
      find.descendant(of: dialog, matching: find.text('lan')),
      findsOneWidget,
      reason: 'the active provider is preselected',
    );
    await tester.tap(find.byKey(apiKeyProviderKey));
    await tester.pump();
    expect(find.text('a'), findsWidgets);
    expect(find.text('local'), findsNothing, reason: 'takes no key');
  });
}
