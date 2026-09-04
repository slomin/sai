import 'fallback.dart';
import 'privacy.dart';
import 'provider.dart';

/// What the status line shows while no provider is selected.
const noProviderStatus = 'no provider — local only';

/// What it shows when the settings file could not be used (ADR 0006).
const unreadableSettingsStatus = 'settings unreadable — local only';

/// What it shows when the selected id is not in this build's registry.
String missingProviderStatus(String id) =>
    "provider '$id' is not available — local only";

/// The status line for a provider: name, default model, privacy tag, and
/// — for a cloud one the switch passes over (#62) — that it will not be
/// used. The same in every client.
String llmStatusLine(LlmProvider provider, {required PrivacyPolicy policy}) =>
    '${provider.displayName} (${provider.defaultModel}) — '
    '${provider.privacy.name}'
    '${policy.withholdsFrom(provider.privacy) ? cloudSkippedSuffix : ''}';

/// Appended to a cloud provider's line while "allow cloud providers to
/// see my tasks" is off: the order passes it over entirely (#62, ADR
/// 0010's amendment) rather than letting it answer without the list.
const cloudSkippedSuffix = ' · cloud not allowed';

/// Appended to the answering provider's line when it is not the first
/// choice: which entry was passed over, and why (`· lan unreachable`).
/// Empty when the first choice answered.
String fallbackSuffix(LlmResolution resolution) =>
    resolution.isFallback && resolution.skipped.isNotEmpty
    ? ' · ${resolution.skipped.first.id} ${resolution.skipped.first.word}'
    : '';

/// Why a send was refused when nothing in the preference order could
/// answer: every entry passed over, in order, with its reason.
String noEligibleProviderError(List<SkippedProvider> skipped) => skipped.isEmpty
    ? noProviderStatus
    : 'no provider can answer — '
          '${skipped.map((skip) => '${skip.id} ${skip.word}').join(', ')}';

/// What it shows when the selected provider is configured but no
/// factory in this build knows its kind.
String unavailableKindStatus(String id, String kind) =>
    "provider '$id' has kind '$kind', which this sai cannot build — "
    'local only';

/// What it shows when the selected provider's kind is known but its
/// configuration lacks what the kind needs (an endpoint, a model).
String misconfiguredStatus(String id, String missing) =>
    "provider '$id' is ${misconfiguredNote(missing)} — local only";

/// The one-line note both clients show beside a provider whose kind
/// refused its configuration: a bare settings key is one it lacks (see
/// `llmKindNeeds`); a phrase is a value that is there and wrong, said as
/// the kind said it (`openRouterProblem`).
String misconfiguredNote(String missing) =>
    missing.contains(' ') ? missing : 'missing its $missing';

/// Appended to the status line when the provider names a credential the
/// secret store does not hold.
const missingCredentialSuffix = ' · no key';

/// Where the cache warmer stands (#105): nothing to do, ingesting the
/// catalog prefix, or the endpoint holds the current prefix.
enum WarmPhase { idle, warming, warm }

/// The warmer's state, for the clients' indicator. [fraction] estimates
/// how much of the prompt is ingested, 0..1, while warming — null until
/// a first completed warm has taught the machine's rate.
final class WarmState {
  const WarmState(this.phase, {this.fraction});

  final WarmPhase phase;
  final double? fraction;

  @override
  bool operator ==(Object other) =>
      other is WarmState && other.phase == phase && other.fraction == fraction;

  @override
  int get hashCode => Object.hash(phase, fraction);

  @override
  String toString() => 'WarmState(${phase.name}, $fraction)';
}

/// The words both clients put beside the connection while the catalog
/// is being ingested; a percentage once the machine's rate is known.
String warmingWord(double? fraction) => fraction == null
    ? 'warming up…'
    : 'warming up ${(fraction * 100).round()}%';

/// Appended when the key is there and bound to this endpoint.
const setCredentialSuffix = ' · key set';

/// Appended when the key is there but was entered for another endpoint.
const reenterCredentialSuffix = ' · key needs re-entry';

/// Appended when the secret store could not be asked.
const unavailableSecretsSuffix = ' · keychain unavailable';

/// Appended in the dev flavor, which holds no credentials (#95).
const absentCredentialSuffix = ' · no credentials in dev';
