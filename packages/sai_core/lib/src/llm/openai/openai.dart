import '../../settings/provider_config.dart';
import '../provider.dart';

/// The `openai` kind (#26): OpenAI's own Responses API, on one origin,
/// billed to an API project, keyed from the Keychain. Not the ChatGPT
/// subscription — that is `chatgpt_subscription`, another kind with
/// another billing, and nothing ever falls from one to the other.
const openAiKind = 'openai';

/// Where every `openai` request goes; nothing in settings or the
/// environment moves it (a test hands the factory a loopback stub).
final openAiEndpoint = Uri.parse('https://api.openai.com/v1');

/// The Responses API's reasoning-effort vocabulary as documented on
/// 2026-09-01 — what the clients offer beside "Model default". Which of
/// them a given model takes is the model's business: the list is labelled
/// "availability depends on the model" and never validates a choice; an
/// unsupported pair fails once, in fixed words, on the recorded Test.
const openAiEffortWords = [
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
];

/// Why [config] cannot be built as an `openai` provider, or null when it
/// can — a bare key for what is missing, a phrase for what is there and
/// wrong (the `openRouterProblem` convention). The endpoint is fixed, the
/// tag is cloud, routing is OpenRouter's word, and the entry needs one
/// exact model and the account its key is filed under.
String? openAiProblem(ProviderConfig config) {
  if (config.endpoint != null) {
    return 'carrying an endpoint, but openai has a fixed one';
  }
  if (config.privacy == LlmPrivacy.local) {
    return 'tagged local, but openai is a cloud provider';
  }
  if (config.routing != null) {
    return 'carrying a routing word, which only openrouter takes';
  }
  if (config.defaultModel == null) return 'default_model';
  if (config.credential == null) return 'credential';
  return null;
}
