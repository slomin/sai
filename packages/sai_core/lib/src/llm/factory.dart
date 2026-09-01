import '../secrets/secret_store.dart';
import '../settings/endpoint.dart';
import '../settings/provider_config.dart';
import 'fake.dart';
import 'openai_compatible/provider.dart';
import 'openrouter.dart';
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
/// Its privacy tag comes from its configuration, `local` by default, so
/// the policy (#27) can be tried without a cloud backend.
LlmProvider fakeProviderFactory(ProviderConfig config, SecretStore secrets) =>
    FakeLlmProvider(
      id: config.id,
      displayName: config.id,
      defaultModel: config.defaultModel ?? 'fake-1',
      privacy: config.privacy ?? LlmPrivacy.local,
    );

/// What each kind must find in its configuration before it can be built,
/// by the settings key name. The registry leaves a provider missing one
/// of these out and names the gap; the factory refuses it too.
const llmKindNeeds = <String, List<String>>{
  'openai_compatible': ['endpoint', 'default_model'],
};

/// The first key of [llmKindNeeds] that [config] lacks, or null. The
/// `openrouter` kind judges its own (`openRouterProblem`): an absent key
/// by name, a wrong value as a phrase — either way the entry is
/// misconfigured, never built and never silently re-routed.
String? missingForKind(ProviderConfig config) {
  if (config.kind == openRouterKind) return openRouterProblem(config);
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

/// The privacy tag an `openai_compatible` endpoint gets when its
/// configuration names none: `local` for this machine and the LAN (#22),
/// `cloud` for any other host — the safe default, since a `/v1` on a
/// public name is as likely to be a hosted service as a home server.
LlmPrivacy defaultPrivacyFor(Uri endpoint) =>
    isPrivateHost(endpoint.host) ? LlmPrivacy.local : LlmPrivacy.cloud;

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
  final uri = Uri.parse(endpoint);
  return OpenAiCompatibleProvider(
    id: config.id,
    endpoint: uri,
    defaultModel: model,
    secrets: secrets,
    credential: config.credential,
    credentialOrigin: config.credentialOrigin,
    privacy: config.privacy ?? defaultPrivacyFor(uri),
  );
}
