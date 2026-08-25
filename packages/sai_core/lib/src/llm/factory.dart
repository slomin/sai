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

/// The `openai_compatible` kind (#22). Throws [ArgumentError] when the
/// configuration lacks the endpoint or the default model the transport
/// needs — the registry then leaves the provider out and the status line
/// says so, rather than building one that can only fail.
LlmProvider openAiCompatibleFactory(
  ProviderConfig config,
  SecretStore secrets,
) {
  final endpoint = config.endpoint;
  final model = config.defaultModel;
  if (endpoint == null) {
    throw ArgumentError('openai_compatible needs endpoint');
  }
  if (model == null) {
    throw ArgumentError('openai_compatible needs default_model');
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
