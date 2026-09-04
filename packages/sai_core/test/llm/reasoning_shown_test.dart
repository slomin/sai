import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

/// Whether the clients show the model's reasoning (#26): for a provider
/// that carries its own effort, whenever that effort is not `none`; for
/// every other kind, the switch — exactly what the request carries.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_reasoning_shown');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  ProviderContainer make() => ProviderContainer.test(
    overrides: [
      archiveRootProvider.overrideWithValue(Directory('${tmp.path}/archive')),
      settingsFileProvider.overrideWithValue(File('${tmp.path}/settings.json')),
      eventSourceProvider.overrideWithValue('sai/test'),
      secretStoreProvider.overrideWithValue(InMemorySecretStore()),
      builtinLlmsProvider.overrideWithValue([FakeLlmProvider.new]),
      defaultLlmIdProvider.overrideWithValue('fake'),
    ],
  );

  test('follows the switch for a provider without an effort of its own', () {
    final container = make();
    addTearDown(container.dispose);
    final settings = container.read(settingsProvider.notifier);
    settings.setReasoning(false);
    expect(container.read(reasoningShownProvider), isFalse);
    settings.setReasoning(true);
    expect(container.read(reasoningShownProvider), isTrue);
  });

  test('follows the entry\'s effort for an OpenAI kind, whatever the switch '
      'says', () {
    final container = make();
    addTearDown(container.dispose);
    final settings = container.read(settingsProvider.notifier);
    settings.setReasoning(false);
    ProviderConfig entry(String? effort) => ProviderConfig(
      id: 'openai',
      kind: openAiKind,
      defaultModel: 'gpt-5.6-sol',
      credential: 'provider:openai',
      reasoningEffort: effort,
    );
    settings.upsertProvider(entry('high'));
    settings.selectLlm('openai');
    // It must be the provider that answers for its effort to be the one
    // the next request carries (#62): a cloud kind needs its key and the
    // sharing switch.
    container.read(credentialsProvider.notifier).set('openai', 'k');
    settings.setShareTasksWithCloud(true);
    expect(container.read(activeLlmProvider)?.id, 'openai');
    expect(container.read(reasoningShownProvider), isTrue);
    settings.upsertProvider(entry(null));
    expect(
      container.read(reasoningShownProvider),
      isTrue,
      reason: 'Model default may reason',
    );
    settings.upsertProvider(entry('none'));
    expect(container.read(reasoningShownProvider), isFalse);
    settings.setReasoning(true);
    expect(
      container.read(reasoningShownProvider),
      isFalse,
      reason: 'the switch is not this provider\'s',
    );
  });
}
