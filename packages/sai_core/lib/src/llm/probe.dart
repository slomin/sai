import 'call.dart';
import 'failure.dart';

/// What an endpoint said about itself when last asked.
enum EndpointHealth {
  /// It answered and is ready.
  ok,

  /// It answered that it is still loading (llama.cpp's 503).
  loading,

  /// It could not be asked; [EndpointInfo.failure] says why.
  unavailable,

  /// Not asked yet.
  unknown,
}

/// The metadata a provider dialog shows per endpoint — never guessed:
/// what the server did not say stays null.
final class EndpointInfo {
  const EndpointInfo({
    this.health = EndpointHealth.unknown,
    this.models = const [],
    this.contextWindow,
    this.serverKind,
    this.failure,
  });

  final EndpointHealth health;

  /// Model ids from `GET /v1/models`.
  final List<String> models;

  /// The configured context size, in tokens, where the server exposes it
  /// (llama.cpp `/props`, LM Studio's loaded instance).
  final int? contextWindow;

  /// `llama.cpp`, `lmstudio`, or null for a server that only speaks the
  /// common API.
  final String? serverKind;

  /// Why [health] is [EndpointHealth.unavailable].
  final LlmFailure? failure;

  @override
  String toString() =>
      'EndpointInfo(${health.name}, ${models.length} models'
      '${contextWindow == null ? '' : ', ctx $contextWindow'}'
      '${serverKind == null ? '' : ', $serverKind'}'
      '${failure == null ? '' : ', $failure'})';
}

/// A provider that can describe its endpoint. Probing is not a call: it
/// is not recorded, and it never throws — trouble comes back as
/// [EndpointInfo.failure].
abstract interface class LlmEndpointProbe {
  Future<EndpointInfo> probe();
}

/// The neutral prompt both clients send when the user asks to test an
/// endpoint. Goes through the recorder like any call, so the result and
/// the tokens/s are on record.
const providerTestPrompt = 'Reply with the single word: ready.';

/// The test request. The budget is generous because a reasoning model
/// spends most of it thinking before the one word.
LlmRequest providerTestRequest() => LlmRequest(
  messages: const [LlmMessage(LlmRole.user, providerTestPrompt)],
  maxTokens: 512,
  temperature: 0,
);
