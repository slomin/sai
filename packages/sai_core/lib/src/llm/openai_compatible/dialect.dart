import '../call.dart';
import '../failure.dart';
import '../probe.dart';

/// What one bounded discovery GET answered: the status, the decoded body
/// when it was JSON, or the failure that stands for it.
final class DiscoveryAnswer {
  DiscoveryAnswer(this.status, {this.json, this.failure});

  final int status;
  final Object? json;
  final LlmFailure? failure;
}

/// What a dialect's probe may use: one bounded GET on the provider's
/// client, the `/v1` base and the root beside it, and what the provider
/// was configured with. Nothing here opens a socket of its own.
final class Discovery {
  const Discovery({
    required this.get,
    required this.base,
    required this.origin,
    required this.wantsLoadedModel,
    required this.defaultModel,
  });

  /// One GET with the transport's rules (no redirects, capped body,
  /// deadlines); a non-2xx answer is for the caller to judge.
  final Future<DiscoveryAnswer> Function(Uri uri) get;

  /// The `/v1` base.
  final Uri base;

  /// `scheme://host[:port]` — what a failure names.
  final String origin;

  /// Whether the provider names no model of its own (LM Studio's
  /// "whatever is loaded").
  final bool wantsLoadedModel;

  final String defaultModel;

  Uri under(String path) => base.replace(path: '${base.path}$path');
  Uri atRoot(String path) => base.replace(path: path);
}

/// What differs between OpenAI-compatible backends beyond the endpoint
/// (#24): the settings word for the kind, the headers and body fields a
/// backend wants, whether reasoning-off is negotiated or simply said, how
/// a refusal reads, and how the endpoint is asked about itself. The
/// transport — direct, bounded, redirect-free, key read at call time
/// (ADR 0009) — is the same for every dialect and lives in the provider.
abstract interface class OpenAiDialect {
  /// The `kind` a `ProviderConfig` names for a provider speaking this.
  String get kind;

  /// Headers on every request beyond content type, accept and the key.
  Map<String, String> get headers;

  /// Whether the key is sent only to the origin it was entered for
  /// (ADR 0009). False for a dialect whose endpoint never moves.
  bool get bindsKeyToOrigin;

  /// Whether reasoning-off is negotiated the local way — OpenAI's
  /// `reasoning_effort: none` plus llama.cpp's `chat_template_kwargs`,
  /// each dropped after a 400 — or said once in [fields].
  bool get negotiatesReasoning;

  /// Body fields beyond `model`, `messages`, `stream`, `max_tokens`,
  /// `temperature` and `response_format`.
  Map<String, Object?> fields(LlmRequest request, {required bool reasoningOff});

  /// Fixed text for a non-2xx status this dialect can name, or null for
  /// the common words (`rejectedKey`, `answered(status)`).
  String? refusal(int status);

  /// What the endpoint says about itself. Never throws: trouble comes
  /// back as [EndpointInfo.failure].
  Future<EndpointInfo> probe(Discovery discovery);
}

/// The local backends (#22): llama.cpp's `llama-server`, LM Studio, the
/// LAN box. Usage is asked for with `stream_options`; reasoning-off is
/// negotiated; discovery reads `/v1/models`, llama.cpp's `/health` and
/// `/props`, LM Studio's `/api/v1/models`.
final class LocalDialect implements OpenAiDialect {
  const LocalDialect();

  @override
  String get kind => 'openai_compatible';

  @override
  Map<String, String> get headers => const {};

  @override
  bool get bindsKeyToOrigin => true;

  @override
  bool get negotiatesReasoning => true;

  @override
  Map<String, Object?> fields(
    LlmRequest request, {
    required bool reasoningOff,
  }) => const {
    'stream_options': {'include_usage': true},
  };

  @override
  String? refusal(int status) => null;

  @override
  Future<EndpointInfo> probe(Discovery d) async {
    final models = await d.get(d.under('/models'));
    if (models.failure != null) {
      return EndpointInfo(
        health: EndpointHealth.unavailable,
        failure: models.failure,
      );
    }
    final ids = <String>[];
    final list = models.json;
    if (list is Map<String, Object?> && list['data'] is List) {
      for (final m in list['data'] as List) {
        if (m is Map<String, Object?> && m['id'] is String) {
          ids.add(m['id'] as String);
        }
      }
    }
    // llama.cpp says so on /health — `{"status":"ok"}`, or a 503 whose
    // error carries the code while the model loads. Only that shape
    // counts: LM Studio answers any unknown path with a 200 and an error
    // body. LM Studio says so on /api/v1/models; anything else is taken
    // at its /v1/models word.
    final [health, lm] = await Future.wait([
      d.get(d.atRoot('/health')),
      d.get(d.atRoot('/api/v1/models')),
    ]);
    final h = health.json;
    final ok =
        health.status == 200 &&
        h is Map<String, Object?> &&
        h['status'] == 'ok';
    final loading =
        health.status == 503 &&
        h is Map<String, Object?> &&
        h['error'] is Map<String, Object?> &&
        (h['error'] as Map<String, Object?>)['code'] == 503;
    if (ok || loading) {
      final props = await d.get(d.atRoot('/props'));
      int? ctx;
      final p = props.json;
      if (p is Map<String, Object?>) {
        final settings = p['default_generation_settings'];
        if (settings is Map<String, Object?> && settings['n_ctx'] is int) {
          ctx = settings['n_ctx'] as int;
        }
      }
      return EndpointInfo(
        health: ok ? EndpointHealth.ok : EndpointHealth.loading,
        models: ids,
        contextWindow: ctx,
        serverKind: 'llama.cpp',
      );
    }
    final l = lm.json;
    if (lm.status == 200 && l is Map<String, Object?> && l['models'] is List) {
      int? ctx;
      for (final m in l['models'] as List) {
        if (m is! Map<String, Object?>) continue;
        // The configured model, or with the loaded model the first LLM
        // that is loaded — the one LM Studio would answer with.
        if (d.wantsLoadedModel
            ? (m['type'] != 'llm' || ctx != null)
            : m['key'] != d.defaultModel) {
          continue;
        }
        final loaded = m['loaded_instances'];
        if (loaded is List && loaded.isNotEmpty) {
          final first = loaded.first;
          final config = first is Map<String, Object?> ? first['config'] : null;
          if (config is Map<String, Object?> &&
              config['context_length'] is int) {
            ctx = config['context_length'] as int;
          }
        }
      }
      return EndpointInfo(
        health: EndpointHealth.ok,
        models: ids,
        contextWindow: ctx,
        serverKind: 'lmstudio',
      );
    }
    return EndpointInfo(health: EndpointHealth.ok, models: ids);
  }
}
