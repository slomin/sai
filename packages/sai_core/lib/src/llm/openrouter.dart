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

  /// A 404 is OpenRouter saying no endpoint passed the `provider` filters:
  /// under the preset that is the pin, under exact routing it is the
  /// privacy filters alone — a model with no zero-retention endpoint can
  /// never answer, and the words say so (#115).
  @override
  String? refusal(int status) => switch (status) {
    404 =>
      routing == OpenRouterRouting.deepinfraFp8
          ? TransportText.noRoute
          : TransportText.noPrivateEndpoint,
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
    // No model list and no context window: the catalogue is a later
    // ticket, and a cloud provider's budget stays the conservative one.
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
