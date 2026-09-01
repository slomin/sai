import '../secrets/secret_store.dart';
import '../settings/endpoint.dart';
import '../settings/provider_config.dart';
import 'call.dart';
import 'failure.dart';
import 'openai_compatible/dialect.dart';
import 'openai_compatible/policy.dart';
import 'openai_compatible/provider.dart';
import 'probe.dart';
import 'provider.dart';

/// OpenRouter (#24, ADR 0022): a cloud broker behind one fixed HTTPS
/// origin, spoken through the common transport with its own dialect. The
/// kind is `openrouter`; the key lives under `provider:openrouter` in the
/// Keychain and is read at call time; the endpoint is not configurable.

const openRouterProviderId = 'openrouter';
const openRouterKind = 'openrouter';

/// The one API base. Nothing in settings or the environment moves it;
/// tests point the built-in and the factory at a loopback stub through
/// `openRouterEndpointProvider`.
final openRouterEndpoint = Uri.parse('https://openrouter.ai/api/v1');

/// The recommended model: DeepSeek V4 Flash 0731, pinned to DeepInfra's
/// FP8 endpoint by [OpenRouterRouting.deepinfraFp8].
const openRouterPresetModel = 'deepseek/deepseek-v4-flash-0731';

/// App attribution, fixed (OpenRouter's `HTTP-Referer` is required for an
/// app entry; `X-OpenRouter-Title` names it).
const openRouterReferer = 'https://github.com/slomin/sai';
const openRouterTitle = 'SAI';

/// How a request may be routed inside OpenRouter. Persisted as
/// `ProviderConfig.routing` by [word]; never inferred from the model.
enum OpenRouterRouting {
  /// The recommended preset: [openRouterPresetModel] on DeepInfra, FP8,
  /// no fallback to another host or quantization. A route that is not
  /// there fails; it is never relaxed.
  deepinfraFp8('deepinfra_fp8'),

  /// One exact model id; OpenRouter picks among that model's endpoints.
  /// Never another model.
  exact('exact');

  const OpenRouterRouting(this.word);

  /// The settings word.
  final String word;

  static OpenRouterRouting? parse(String? word) {
    for (final r in values) {
      if (r.word == word) return r;
    }
    return null;
  }

  /// The `provider` object on every request. Both modes deny data
  /// collection, require zero data retention and refuse an endpoint that
  /// would drop a parameter; the preset adds the pin.
  Map<String, Object?> get wire => switch (this) {
    deepinfraFp8 => const {
      'only': ['deepinfra'],
      'quantizations': ['fp8'],
      'allow_fallbacks': false,
      'require_parameters': true,
      'data_collection': 'deny',
      'zdr': true,
    },
    exact => const {
      'require_parameters': true,
      'data_collection': 'deny',
      'zdr': true,
    },
  };

  /// What the clients say beside the model.
  String get label => switch (this) {
    deepinfraFp8 => 'pinned to DeepInfra fp8',
    exact => 'exact model',
  };

  /// What a 404 means under this routing: the pin was not there, or —
  /// with no pin — the model is not on OpenRouter or none of its endpoints
  /// passes the privacy filters (#115). Exhaustive, like [wire] and
  /// [label], so a new mode has to say which.
  String get noEndpointText => switch (this) {
    deepinfraFp8 => TransportText.noRoute,
    exact => TransportText.noExactEndpoint,
  };
}

/// The zero-retention endpoint list (#112): every endpoint OpenRouter
/// would route to under `zdr: true`, one row per endpoint, public. Read
/// on demand only — never on the probe — for `model_id` and nothing else.
const openRouterZdrPath = '/endpoints/zdr';

/// The most the list may be: ~0.7 MB for 816 rows on 2026-09-01, so
/// eleven times that before it is refused as too large.
const maxOpenRouterCatalogueBytes = 8 << 20;

/// How many suggestions the picker shows at most.
const openRouterCatalogueMatchLimit = 50;

/// The exact model ids in a `/endpoints/zdr` answer — the strings under
/// `data[].model_id` that pass [openRouterModelProblem], deduplicated
/// (several endpoints serve one model) and sorted — or null when the
/// answer is not a list of endpoints at all. A malformed row is skipped,
/// never fatal; every other field is ignored.
List<String>? zdrModelIds(Object? json) {
  if (json is! Map<String, Object?> || json['data'] is! List) return null;
  final ids = <String>{};
  for (final row in json['data'] as List) {
    if (row is Map<String, Object?> && row['model_id'] is String) {
      final id = row['model_id'] as String;
      if (openRouterModelProblem(id) == null) ids.add(id);
    }
  }
  return ids.toList()..sort();
}

/// The suggestions for [query] out of [models], a sorted id list: the
/// ids that start with the lowercased query, then the ones that contain
/// it, [limit] at most, in the list's order within each rank — the same
/// answer for the same input, always. Nothing for nothing typed: the
/// list is offered as one types, never dropped over what sits below the
/// field because it was clicked or cleared.
List<String> openRouterCatalogueMatches(
  List<String> models,
  String query, {
  int limit = openRouterCatalogueMatchLimit,
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

/// What one reading of the zero-retention list came to: the sorted ids,
/// or the failure in fixed words.
typedef OpenRouterCatalogueAnswer = ({
  List<String>? models,
  LlmFailure? failure,
});

/// Reads the zero-retention list through [provider] — an OpenRouter one,
/// or [ArgumentError]. One GET on the provider's prepared path (no key,
/// no request; the dev copy refuses before a socket), bounded by
/// [maxBytes]; the body is parsed for ids and dropped.
Future<OpenRouterCatalogueAnswer> fetchOpenRouterCatalogue(
  OpenAiCompatibleProvider provider, {
  int maxBytes = maxOpenRouterCatalogueBytes,
}) async {
  if (openRouterRoutingOf(provider) == null) {
    throw ArgumentError('the zero-retention list is OpenRouter\'s alone');
  }
  final answer = await provider.fetch(openRouterZdrPath, maxBytes: maxBytes);
  if (answer.failure != null) return (models: null, failure: answer.failure);
  final ids = zdrModelIds(answer.json);
  if (ids == null) {
    return (
      models: null,
      failure: LlmFailure(
        LlmFailureKind.protocol,
        TransportText.notEndpoints,
        endpoint: provider.origin,
      ),
    );
  }
  return (models: ids, failure: null);
}

/// What the running sai knows of OpenRouter's zero-retention models
/// (#112): the last list read, whether one is being read now, and how
/// the last attempt failed, if it did. Session state, written nowhere;
/// a failed refresh keeps the last list beside its failure, and a list
/// is guidance — an endpoint listed now may be gone by the next call.
final class OpenRouterCatalogue {
  const OpenRouterCatalogue({this.models, this.loading = false, this.failure});

  /// The sorted exact ids of the last successful reading, or null
  /// before one.
  final List<String>? models;

  /// Whether a reading is under way.
  final bool loading;

  /// How the last reading failed; null after a success.
  final LlmFailure? failure;

  /// Whether the session has tried at all, however it went.
  bool get attempted => models != null || failure != null || loading;

  @override
  String toString() =>
      'OpenRouterCatalogue(${models?.length ?? 'no'} models'
      '${loading ? ', loading' : ''}'
      '${failure == null ? '' : ', ${failure!.message}'})';
}

/// One exact OpenRouter model id: `owner/name`, no router, no alias.
final openRouterModelForm = RegExp(
  r'^[a-z0-9][a-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._:-]*$',
);

/// Suffixes that hand routing back to OpenRouter (`:nitro` sorts by
/// throughput, `:floor` by price) or add a web search (`:online`).
const openRouterShortcuts = [':nitro', ':floor', ':online'];

/// Why [model] is not one exact model id, in a sentence, or null. Judged
/// on the lowercased id: OpenRouter's slugs are lowercase and a router
/// spelled `openrouter/Auto` would still be the router. Every id under
/// the `openrouter/` owner is a router — `auto`, `auto-beta`, `free`, and
/// whatever comes next — so the owner is refused, not a list of names.
String? openRouterModelProblem(String model) {
  final id = model.toLowerCase();
  if (!openRouterModelForm.hasMatch(model)) {
    return 'an OpenRouter model id is owner/name';
  }
  if (id.startsWith('openrouter/')) {
    return 'openrouter/* ids are routers that pick the model; name one';
  }
  for (final s in openRouterShortcuts) {
    if (id.endsWith(s)) {
      return 'the $s shortcut changes the routing; name the model alone';
    }
  }
  return null;
}

/// Why [config] cannot be built as an `openrouter` provider, or null when
/// it can. A key that is absent is named bare (`default_model`,
/// `credential`, `routing`), the way `llmKindNeeds` names one, so the
/// clients say "missing its …" and the CLI can name the flag; a value
/// that is present and wrong comes back as a phrase, since "missing" and
/// "add it" would send the person the wrong way. The endpoint is not the
/// user's to set, the privacy tag is `cloud` or nothing, the model is one
/// exact id, the routing is a known word that fits the model, and the
/// key's account is named.
String? openRouterProblem(ProviderConfig config) {
  if (config.endpoint != null) {
    return 'carrying an endpoint, but openrouter has a fixed one';
  }
  if (config.privacy == LlmPrivacy.local) {
    return 'tagged local, but openrouter is a cloud provider';
  }
  final model = config.defaultModel;
  if (model == null) return 'default_model';
  if (openRouterModelProblem(model) != null) {
    return 'naming a router or a shortcut, not one exact model';
  }
  if (config.credential == null) return 'credential';
  final routing = OpenRouterRouting.parse(config.routing);
  if (routing == null) {
    return config.routing == null
        ? 'routing'
        : 'carrying a routing word this sai does not know';
  }
  if (routing == OpenRouterRouting.deepinfraFp8 &&
      model != openRouterPresetModel) {
    return 'routed deepinfra_fp8, which fits $openRouterPresetModel only';
  }
  return null;
}

/// The endpoint a test may hand in for the fixed one: a loopback stub and
/// nothing else, so no override can point the key at another host.
Uri _fixedOrigin(Uri? endpoint) {
  if (endpoint == null || endpoint == openRouterEndpoint) {
    return openRouterEndpoint;
  }
  if (!isLoopbackHost(endpoint.host)) {
    throw ArgumentError(
      'the OpenRouter origin moves only to a loopback stub in tests',
    );
  }
  return endpoint;
}

/// OpenRouter's request shape over the common transport: attribution
/// headers, the `provider` routing object, `reasoning: {enabled: false}`
/// when the user turns thinking off (never llama.cpp's template switch,
/// never negotiated — a refusal is a refusal), no `stream_options`
/// (usage, with the cost, is in the final chunk regardless, and
/// `require_parameters` would refuse the field), fixed words for the
/// two statuses that mean something here, and `GET /key` as the probe —
/// a zero-token call that says whether the key is good.
final class OpenRouterDialect implements OpenAiDialect {
  const OpenRouterDialect(this.routing);

  final OpenRouterRouting routing;

  @override
  String get kind => openRouterKind;

  @override
  Map<String, String> get headers => const {
    'HTTP-Referer': openRouterReferer,
    'X-OpenRouter-Title': openRouterTitle,
  };

  /// The origin never moves, so there is nothing to bind the key to.
  @override
  bool get bindsKeyToOrigin => false;

  @override
  bool get negotiatesReasoning => false;

  @override
  Map<String, Object?> fields(
    LlmRequest request, {
    required bool reasoningOff,
  }) => {
    'provider': routing.wire,
    if (reasoningOff) 'reasoning': const {'enabled': false},
  };

  /// A 404 is OpenRouter saying no endpoint was left after the `provider`
  /// filters (or that the model is not there at all); the routing says
  /// which words fit (#115).
  @override
  String? refusal(int status) => switch (status) {
    404 => routing.noEndpointText,
    402 => TransportText.noCredit,
    _ => null,
  };

  @override
  Future<EndpointInfo> probe(Discovery d) async {
    final key = await d.get(d.under('/key'));
    if (key.failure != null) {
      return EndpointInfo(
        health: EndpointHealth.unavailable,
        failure: key.failure,
      );
    }
    // A capped key that has spent its cap still answers 200 here while
    // every call would answer 402: read the one field that says so.
    // Nothing else of the body is kept — it also carries the key's label.
    if (key.json case {'data': {'limit_remaining': final num left}}
        when left <= 0) {
      return EndpointInfo(
        health: EndpointHealth.unavailable,
        failure: LlmFailure(
          LlmFailureKind.rejected,
          TransportText.noCredit,
          endpoint: d.origin,
        ),
      );
    }
    // No model list here — the zero-retention list is read on demand
    // (#112, [fetchOpenRouterCatalogue]), never on the probe's timer —
    // and no context window: a cloud provider's budget stays the
    // conservative one.
    return const EndpointInfo(
      health: EndpointHealth.ok,
      serverKind: openRouterKind,
    );
  }
}

/// How [provider] routes inside OpenRouter, or null for any other
/// provider — what both clients append to its line.
OpenRouterRouting? openRouterRoutingOf(LlmProvider provider) =>
    provider is OpenAiCompatibleProvider &&
        provider.dialect is OpenRouterDialect
    ? (provider.dialect as OpenRouterDialect).routing
    : null;

/// The `openrouter` kind. Throws [ArgumentError] when [openRouterProblem]
/// names one. The endpoint is [openRouterEndpoint] unless a test hands
/// over its stub; the privacy tag is always `cloud`.
LlmProvider openRouterFactory(
  ProviderConfig config,
  SecretStore secrets, {
  Uri? endpoint,
}) {
  final problem = openRouterProblem(config);
  if (problem != null) {
    throw ArgumentError('openrouter: its $problem is missing or wrong');
  }
  return OpenAiCompatibleProvider(
    id: config.id,
    endpoint: _fixedOrigin(endpoint),
    defaultModel: config.defaultModel!,
    secrets: secrets,
    credential: config.credential,
    privacy: LlmPrivacy.cloud,
    dialect: OpenRouterDialect(OpenRouterRouting.parse(config.routing)!),
  );
}

/// The built-in (#24): the recommended preset, inactive until selected,
/// keyless until a key is stored under `provider:openrouter`. A
/// configured `openrouter` entry replaces it.
OpenAiCompatibleProvider openRouterBuiltin(
  SecretStore secrets, {
  Uri? endpoint,
}) => OpenAiCompatibleProvider(
  id: openRouterProviderId,
  endpoint: _fixedOrigin(endpoint),
  defaultModel: openRouterPresetModel,
  secrets: secrets,
  credential: ProviderConfig.credentialFor(openRouterProviderId),
  privacy: LlmPrivacy.cloud,
  dialect: const OpenRouterDialect(OpenRouterRouting.deepinfraFp8),
);
