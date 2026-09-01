import '../../secrets/secret_store.dart';
import '../../settings/provider_config.dart';
import '../call.dart';
import '../failure.dart';
import '../openai_compatible/policy.dart';
import '../provider.dart';
import 'provider.dart';

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

/// The `openai` kind. Throws [ArgumentError] when [openAiProblem] names
/// one. The endpoint is [openAiEndpoint] unless a test hands over its
/// loopback stub; the privacy tag is always `cloud`; the effort is the
/// entry's own word, or Model default.
LlmProvider openAiFactory(
  ProviderConfig config,
  SecretStore secrets, {
  Uri? endpoint,
}) {
  final problem = openAiProblem(config);
  if (problem != null) {
    throw ArgumentError('openai: its $problem is missing or wrong');
  }
  return OpenAiResponsesProvider(
    id: config.id,
    defaultModel: config.defaultModel!,
    secrets: secrets,
    credential: config.credential!,
    reasoningEffort: ReasoningEffort.parse(config.reasoningEffort),
    endpoint: endpoint,
  );
}

/// The ids in a `GET /v1/models` answer — `data[].id`, sorted — or null
/// when the answer is not a list of models at all. The list says which
/// ids the key can reach; it says nothing about which take the Responses
/// API or which effort, so the clients label it guidance, and a typed id
/// stands whether or not it is listed.
List<String>? openAiModelIds(Object? json) {
  if (json is! Map<String, Object?> || json['data'] is! List) return null;
  final ids = <String>{};
  for (final row in json['data'] as List) {
    if (row is Map<String, Object?> && row['id'] is String) {
      ids.add(row['id'] as String);
    }
  }
  return ids.toList()..sort();
}

/// What one reading of the model list came to: the sorted ids, or the
/// failure in fixed words.
typedef OpenAiCatalogueAnswer = ({List<String>? models, LlmFailure? failure});

/// Reads the model list through [provider]: one GET on its prepared
/// path (no key, no request; the dev copy refuses before a socket). The
/// body is parsed for ids and dropped.
Future<OpenAiCatalogueAnswer> fetchOpenAiCatalogue(
  OpenAiResponsesProvider provider,
) async {
  final answer = await provider.fetch('/models');
  if (answer.failure != null) return (models: null, failure: answer.failure);
  final ids = openAiModelIds(answer.json);
  if (ids == null) {
    return (
      models: null,
      failure: LlmFailure(
        LlmFailureKind.protocol,
        TransportText.notModels,
        endpoint: provider.origin,
      ),
    );
  }
  return (models: ids, failure: null);
}

/// What the session knows of the `openai` model list (#26): read once a
/// key is stored and on Refresh, kept for the session, written nowhere.
final class OpenAiCatalogue {
  const OpenAiCatalogue({
    this.id,
    this.models,
    this.loading = false,
    this.failure,
  });

  /// The `openai` entry the reading was made through — each key sees
  /// its own list, so a second entry is read afresh, never shown the
  /// first's.
  final String? id;

  /// The sorted ids of the last successful reading, or null before one.
  final List<String>? models;

  /// Whether a reading is under way.
  final bool loading;

  /// How the last reading failed; null after a success.
  final LlmFailure? failure;

  /// Whether the session has tried at all, however it went.
  bool get attempted => models != null || failure != null || loading;

  @override
  String toString() =>
      'OpenAiCatalogue(${id == null ? '' : '$id: '}${models?.length ?? 'no'} models'
      '${loading ? ', loading' : ''}'
      '${failure == null ? '' : ', ${failure!.message}'})';
}

/// The suggestions for [query] out of [models]: ids that start with the
/// lowercased query first, then the ones that contain it, [limit] at
/// most — the same ranking the OpenRouter picker uses. Nothing for
/// nothing typed.
List<String> openAiCatalogueMatches(
  List<String> models,
  String query, {
  int limit = 50,
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const [];
  final starts = <String>[];
  final within = <String>[];
  for (final id in models) {
    final lower = id.toLowerCase();
    if (lower.startsWith(needle)) {
      starts.add(id);
      if (starts.length >= limit) break;
    } else if (lower.contains(needle)) {
      within.add(id);
    }
  }
  return [...starts, ...within].take(limit).toList();
}
