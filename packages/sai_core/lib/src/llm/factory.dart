import '../secrets/secret_store.dart';
import '../settings/provider_config.dart';
import 'fake.dart';
import 'openai_compatible/provider.dart';
import 'provider.dart';

/// Builds an [LlmProvider] from its configuration. The secret store is
/// handed over, not a key: a provider reads its credential when it needs
/// it, so a key entered after startup is used on the next call and a key
/// never sits in settings state.
typedef LlmProviderFactory = LlmProvider Function(
  ProviderConfig config,
  SecretStore secrets,
);

/// The `fake` kind: a configured fake, for offline demos and tests that
/// want a provider to come from settings rather than from the built-ins.
LlmProvider fakeProviderFactory(ProviderConfig config, SecretStore secrets) =>
    FakeLlmProvider(
      id: config.id,
      displayName: config.id,
      defaultModel: config.defaultModel ?? 'fake-1',
    );

/// What each kind must find in its configuration before it can be built,
/// by the settings key name. The registry leaves a provider missing one
/// of these out and names the gap; the factory refuses it too.
const llmKindNeeds = <String, List<String>>{
  'openai_compatible': ['endpoint', 'default_model'],
};

/// The first key of [llmKindNeeds] that [config] lacks, or null.
String? missingForKind(ProviderConfig config) {
  for (final key in llmKindNeeds[config.kind] ?? const <String>[]) {
    final present = switch (key) {
      'endpoint' => config.endpoint != null,
      'default_model' => config.defaultModel != null,
      _ => true,
    };
    if (!present) return key;
  }
  return null;
}

/// The `openai_compatible` kind (#22). Throws [ArgumentError] when the
/// configuration lacks what [llmKindNeeds] lists.
LlmProvider openAiCompatibleFactory(
  ProviderConfig config,
  SecretStore secrets,
) {
  final endpoint = config.endpoint;
  final model = config.defaultModel;
  if (endpoint == null || model == null) {
    throw ArgumentError('openai_compatible needs ${missingForKind(config)}');
  }
  return OpenAiCompatibleProvider(
    id: config.id,
    endpoint: Uri.parse(endpoint),
    defaultModel: model,
    secrets: secrets,
    credential: config.credential,
    credentialOrigin: config.credentialOrigin,
  );
}
