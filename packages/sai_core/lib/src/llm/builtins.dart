import '../secrets/secret_store.dart';
import '../settings/provider_config.dart';
import 'fake.dart';
import 'openai_compatible/provider.dart';
import 'openrouter.dart';
import 'provider.dart';

/// The providers every build ships without configuration (#23): the
/// offline fake, LM Studio on this Mac, the LAN inference box, and
/// OpenRouter on its recommended preset (#24). A configured provider
/// with the same id replaces the built-in one, so `provider add lmstudio
/// --model …` or `provider add lan --endpoint …` is how either is
/// changed. Only OpenRouter takes a key, and stays inactive until a
/// person selects it.

/// LM Studio's local server: whatever model it has loaded.
const lmStudioProviderId = 'lmstudio';
final lmStudioEndpoint = Uri.parse('http://127.0.0.1:1234/v1');

/// The LAN box: `llama-server` with Qwen3.8-27B on the full native
/// context (#23). The address is the LAN's, in the clear (ADR 0012).
const lanProviderId = 'lan';
final lanEndpoint = Uri.parse('http://192.168.1.5:8080/v1');
const lanModel = 'sai-qwen38-27b-unsloth-q6k-fullctx-generic-mtp';

/// What a first run selects — a settings file that does not exist yet.
/// A file that says `"llm": null` means none and is left alone.
const defaultLlmId = lmStudioProviderId;

/// How long the built-in fake pauses before each delta: `SAI_FAKE_DELTA_MS`
/// in the environment, for a smoke that wants to see the wait and the
/// stream (#99); zero — at once — when unset or not a count.
Duration fakeDeltaFrom(Map<String, String> environment) {
  final ms = int.tryParse(environment['SAI_FAKE_DELTA_MS'] ?? '') ?? 0;
  return Duration(milliseconds: ms < 0 ? 0 : ms);
}

/// The built-ins as constructors, in the order the clients list them.
/// [openRouterEndpoint] is for tests only: the shipped one is fixed.
List<LlmProvider Function()> builtinLlms(
  SecretStore secrets, {
  Duration fakeDelta = Duration.zero,
  Uri? openRouterEndpoint,
}) => [
  () => FakeLlmProvider(delta: fakeDelta),
  () => OpenAiCompatibleProvider(
    id: lmStudioProviderId,
    endpoint: lmStudioEndpoint,
    defaultModel: OpenAiCompatibleProvider.loadedModel,
    secrets: secrets,
    privacy: LlmPrivacy.local,
  ),
  () => OpenAiCompatibleProvider(
    id: lanProviderId,
    endpoint: lanEndpoint,
    defaultModel: lanModel,
    secrets: secrets,
    privacy: LlmPrivacy.local,
  ),
  () => openRouterBuiltin(secrets, endpoint: openRouterEndpoint),
];

/// The settings entry that would configure [provider] as it stands — what
/// `provider add <id>` seeds from a built-in, and what storing a key for
/// an unconfigured built-in writes first. Null for a provider no kind
/// describes.
ProviderConfig? configFor(LlmProvider provider) => switch (provider) {
  // The kind and the privacy are the provider's own; an entry names an
  // endpoint only for a dialect whose endpoint is the person's to set.
  OpenAiCompatibleProvider() => ProviderConfig(
    id: provider.id,
    kind: provider.kind,
    endpoint: provider.dialect.bindsKeyToOrigin
        ? provider.endpoint.toString()
        : null,
    defaultModel: provider.defaultModel,
    credential: provider.credential,
    privacy: provider.privacy,
    routing: openRouterRoutingOf(provider)?.word,
  ),
  FakeLlmProvider() => ProviderConfig(
    id: provider.id,
    kind: 'fake',
    defaultModel: provider.defaultModel,
    privacy: provider.privacy,
  ),
  _ => null,
};
