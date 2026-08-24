import '../secrets/secret_store.dart';
import '../settings/provider_config.dart';
import 'fake.dart';
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
