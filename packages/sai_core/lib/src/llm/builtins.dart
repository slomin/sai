import '../secrets/secret_store.dart';
import 'fake.dart';
import 'openai_compatible/provider.dart';
import 'provider.dart';

/// The providers every build ships without configuration (#23): the
/// offline fake, LM Studio on this Mac, and the LAN inference box. A
/// configured provider with the same id replaces the built-in one, so
/// `provider add lmstudio --model …` or `provider add lan --endpoint …`
/// is how either is changed. None takes a key.

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

/// The built-ins as constructors, in the order the clients list them.
List<LlmProvider Function()> builtinLlms(SecretStore secrets) => [
  FakeLlmProvider.new,
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
];
