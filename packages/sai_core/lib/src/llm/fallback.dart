import 'privacy.dart';
import 'probe.dart';
import 'provider.dart';

/// Why an entry of the preference order was passed over (#62). The
/// vocabulary the archive's `policy.fallback` line and both clients'
/// status lines share.
enum SkipReason {
  /// Nothing this build can offer answers to that id: no configuration,
  /// or a kind no factory knows.
  unavailable,

  /// Its kind knows the entry but refused its configuration — an
  /// endpoint or a model it does not have.
  misconfigured,

  /// It takes a credential the secret store does not hold, or could not
  /// be asked for.
  noKey,

  /// A `cloud`-tagged provider while "allow cloud providers to see my
  /// tasks" is off (#27, ADR 0010). The order ends at the last local one
  /// rather than falling through to a backend the switch has not
  /// authorised.
  cloudDisallowed,

  /// Its endpoint could not be reached when it was last asked.
  unreachable,

  /// Its endpoint answered that it is still loading a model.
  loading;

  /// The word the archive records — the enum's own name, snake-cased.
  String get wireName => switch (this) {
    SkipReason.unavailable => 'unavailable',
    SkipReason.misconfigured => 'misconfigured',
    SkipReason.noKey => 'no_key',
    SkipReason.cloudDisallowed => 'cloud_disallowed',
    SkipReason.unreachable => 'unreachable',
    SkipReason.loading => 'loading',
  };
}

/// One entry the resolver passed over, and why — in the words both
/// clients show (`lan unreachable`).
final class SkippedProvider {
  const SkippedProvider(this.id, this.reason, {this.detail});

  /// The id as the order names it, whether or not anything is installed
  /// under it.
  final String id;

  final SkipReason reason;

  /// What the reason came down to where the reason alone is too coarse:
  /// the failure kind for [SkipReason.unreachable] (`timeout`,
  /// `rejected`, …) and the secret store's own answer for
  /// [SkipReason.noKey]. Null when the reason says it all.
  final String? detail;

  /// The phrase a status line puts after the id.
  String get word => switch (reason) {
    SkipReason.unavailable => 'not available',
    SkipReason.misconfigured => 'misconfigured',
    SkipReason.noKey => detail ?? 'no key',
    SkipReason.cloudDisallowed => 'cloud not allowed',
    SkipReason.unreachable => detail ?? 'unreachable',
    SkipReason.loading => 'loading',
  };

  Map<String, Object?> toJson() => {
    'provider': id,
    'reason': reason.wireName,
    if (detail != null) 'detail': detail,
  };

  @override
  bool operator ==(Object other) =>
      other is SkippedProvider &&
      other.id == id &&
      other.reason == reason &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(id, reason, detail);

  @override
  String toString() => 'SkippedProvider($id $word)';
}

/// Which provider answers the next request, and what the order passed
/// over to get there (#62).
final class LlmResolution {
  const LlmResolution({this.provider, this.first, this.skipped = const []});

  /// Nothing selected: an empty order, nothing skipped, nothing to say.
  static const none = LlmResolution();

  /// The provider that answers, or null when nothing in the order can.
  final LlmProvider? provider;

  /// The id at the head of the order — the person's first choice —
  /// whatever became of it.
  final String? first;

  /// What was passed over on the way, in order. Empty when the first
  /// choice answered, and complete when nothing did.
  final List<SkippedProvider> skipped;

  /// Whether the answer came from something other than the first choice.
  bool get isFallback => provider != null && provider!.id != first;

  @override
  bool operator ==(Object other) =>
      other is LlmResolution &&
      identical(other.provider, provider) &&
      other.first == first &&
      other.skipped.length == skipped.length &&
      _sameSkips(other.skipped);

  bool _sameSkips(List<SkippedProvider> others) {
    for (var i = 0; i < skipped.length; i++) {
      if (others[i] != skipped[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(provider, first, Object.hashAll(skipped));

  @override
  String toString() =>
      'LlmResolution(${provider?.id}, first: $first, '
      'skipped: $skipped)';
}

/// The entries of the preference order a prober asks about (#62): those
/// that are installed, hold the key they need and are allowed by the
/// privacy policy — health is the only thing left to learn about them.
///
/// Value-equal on the instances, not on the list, so an unrelated
/// settings edit that rebuilds the registry without touching these
/// providers does not restart the walk.
final class LlmCandidates {
  const LlmCandidates(this.providers);

  static const none = LlmCandidates([]);

  /// In the order's own order; the walk stops at the first that answers.
  final List<LlmProvider> providers;

  bool get isEmpty => providers.isEmpty;

  @override
  bool operator ==(Object other) {
    if (other is! LlmCandidates) return false;
    if (other.providers.length != providers.length) return false;
    for (var i = 0; i < providers.length; i++) {
      if (!identical(other.providers[i], providers[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll([
    for (final provider in providers) identityHashCode(provider),
  ]);

  @override
  String toString() =>
      'LlmCandidates(${[for (final p in providers) p.id].join(', ')})';
}

/// The `policy.fallback` payload for [resolution] — written only when
/// the answer did not come from the first choice, so neither
/// [LlmResolution.provider] nor [LlmResolution.first] is null here.
Map<String, Object?> fallbackPayload(LlmResolution resolution) => {
  'first': resolution.first,
  'chosen': resolution.provider!.id,
  'skipped': [for (final skip in resolution.skipped) skip.toJson()],
};

/// Walks the preference [order] and answers with the first entry that
/// can take the next request: installed, buildable, holding the key it
/// needs, allowed by the privacy policy, and not known to be unhealthy.
///
/// Pure — the caller supplies every input, and health is whatever the
/// last probe filed. [EndpointHealth.unknown] is eligible: it means "not
/// asked yet" or "cannot be asked" (the fake), and a send never waits
/// for a probe. Only [EndpointHealth.unavailable] and
/// [EndpointHealth.loading] pass an entry over.
///
/// The ladder is ordered so an entry is never judged on something that
/// does not apply to it — nothing that is not installed is asked about
/// its key or its tag — and stops at the answer: what stands behind the
/// provider that answers was not considered and is not reported.
LlmResolution resolveLlm({
  required List<String> order,
  required Map<String, LlmProvider> registry,
  required Map<String, String> misconfigured,
  required String? Function(String id) credentialProblem,
  required Map<String, EndpointInfo> health,
  required PrivacyPolicy policy,
}) {
  if (order.isEmpty) return LlmResolution.none;
  final skipped = <SkippedProvider>[];
  for (final id in order) {
    final provider = registry[id];
    if (provider == null) {
      skipped.add(
        SkippedProvider(
          id,
          misconfigured.containsKey(id)
              ? SkipReason.misconfigured
              : SkipReason.unavailable,
        ),
      );
      continue;
    }
    if (credentialProblem(id) case final problem?) {
      skipped.add(SkippedProvider(id, SkipReason.noKey, detail: problem));
      continue;
    }
    if (policy.withholdsFrom(provider.privacy)) {
      skipped.add(SkippedProvider(id, SkipReason.cloudDisallowed));
      continue;
    }
    switch (health[id]?.health ?? EndpointHealth.unknown) {
      case EndpointHealth.unavailable:
        skipped.add(
          SkippedProvider(
            id,
            SkipReason.unreachable,
            detail: health[id]?.failure?.kind.name,
          ),
        );
      case EndpointHealth.loading:
        skipped.add(SkippedProvider(id, SkipReason.loading));
      case EndpointHealth.ok || EndpointHealth.unknown:
        return LlmResolution(
          provider: provider,
          first: order.first,
          skipped: List.unmodifiable(skipped),
        );
    }
  }
  return LlmResolution(first: order.first, skipped: List.unmodifiable(skipped));
}
