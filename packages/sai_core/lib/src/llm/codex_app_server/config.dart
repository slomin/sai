import '../../settings/provider_config.dart';
import '../provider.dart';

/// The `chatgpt_subscription` kind (#26, ADR 0013): a ChatGPT plan, used
/// through OpenAI's own Codex App Server running as sai's child. The
/// login belongs to that runtime — sai holds no token and the entry
/// names no credential. Cloud by nature; the model is chosen from what
/// the runtime lists, so an entry may stand without one until it is.
const chatGptKind = 'chatgpt_subscription';

/// Why [config] cannot be built as a `chatgpt_subscription` provider, or
/// null when it can. Everything here is a phrase: the kind has nothing a
/// bare flag could add — no endpoint, no key, no routing — and the model
/// is chosen in the clients from the live list, not typed blind.
String? chatGptProblem(ProviderConfig config) {
  if (config.endpoint != null) {
    return 'carrying an endpoint, but chatgpt_subscription has none';
  }
  if (config.privacy == LlmPrivacy.local) {
    return 'tagged local, but chatgpt_subscription is a cloud provider';
  }
  if (config.routing != null) {
    return 'carrying a routing word, which only openrouter takes';
  }
  if (config.credential != null) {
    return 'naming a key, but the ChatGPT login lives in the App Server, '
        'not the Keychain';
  }
  return null;
}
