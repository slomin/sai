import 'call.dart';
import 'provider.dart';

/// A provider whose reasoning effort is its own setting (#26): the OpenAI
/// kinds carry a `reasoning_effort` in their entry, chosen against the
/// model's advertised vocabulary, and the global on/off switch does not
/// speak for them. Null is "Model default" — the override is omitted on
/// the wire, and the model decides.
abstract interface class ConfiguredEffort {
  ReasoningEffort? get reasoningEffort;
}

/// The effort a request to [provider] carries, decided before the
/// recorder starts (ADR 0011): a [ConfiguredEffort] provider's own word;
/// for every other kind the global switch translated as it always was —
/// on leaves the backend to its default, off asks for `none`.
ReasoningEffort? requestedEffortFor(
  LlmProvider provider, {
  required bool reasoningOn,
}) {
  if (provider case final ConfiguredEffort configured) {
    return configured.reasoningEffort;
  }
  return reasoningOn ? null : ReasoningEffort.none;
}
