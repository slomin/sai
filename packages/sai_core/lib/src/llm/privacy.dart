import 'call.dart';
import 'provider.dart';

/// What became of a request's task context under the policy.
enum TaskContextOutcome {
  /// The request carried none.
  none,

  /// Carried and sent.
  sent,

  /// Carried and dropped before the request was built.
  withheld,
}

/// The privacy policy, v0.1 (#27, ADR 0010): one switch. The task list
/// and the archive are personal data; a `cloud`-tagged provider sees the
/// task context only while [shareTasksWithCloud] is on. A `local`
/// provider always does. The recorder is the only caller — the one place
/// requests are assembled.
final class PrivacyPolicy {
  const PrivacyPolicy({this.shareTasksWithCloud = false});

  /// Off by default: nothing leaves the machine until asked.
  final bool shareTasksWithCloud;

  /// The decision for [request] going to a provider tagged [privacy], or
  /// null for a local provider — nothing is at stake, nothing is
  /// recorded.
  PolicyDecision? decide(LlmPrivacy privacy, LlmRequest request) {
    if (privacy == LlmPrivacy.local) return null;
    final carried = request.taskContext != null;
    return PolicyDecision(
      privacy: privacy,
      shareTasks: shareTasksWithCloud,
      taskContext: !carried
          ? TaskContextOutcome.none
          : shareTasksWithCloud
          ? TaskContextOutcome.sent
          : TaskContextOutcome.withheld,
    );
  }

  /// Whether a provider tagged [privacy] operates without the task list.
  bool withholdsFrom(LlmPrivacy privacy) =>
      privacy == LlmPrivacy.cloud && !shareTasksWithCloud;

  @override
  bool operator ==(Object other) =>
      other is PrivacyPolicy &&
      other.shareTasksWithCloud == shareTasksWithCloud;

  @override
  int get hashCode => shareTasksWithCloud.hashCode;

  @override
  String toString() =>
      'PrivacyPolicy(shareTasksWithCloud: $shareTasksWithCloud)';
}

/// One decision, as written to the archive as a `policy.decision` line
/// before the request it governs.
final class PolicyDecision {
  const PolicyDecision({
    required this.privacy,
    required this.shareTasks,
    required this.taskContext,
  });

  final LlmPrivacy privacy;

  /// The switch as it stood.
  final bool shareTasks;
  final TaskContextOutcome taskContext;

  bool get withheld => taskContext == TaskContextOutcome.withheld;

  Map<String, Object?> toJson() => {
    'privacy': privacy.name,
    'share_tasks': shareTasks,
    'task_context': taskContext.name,
  };

  @override
  String toString() => 'PolicyDecision(${toJson()})';
}

/// What both clients say of a provider operating without the task list.
const tasksWithheldWord = 'tasks withheld';

/// Appended to the status line while the active provider operates
/// without the task list.
const tasksWithheldSuffix = ' · $tasksWithheldWord';

/// The one-line warning both clients show when a cloud provider is
/// selected while sharing is off.
String cloudSelectionWarning(String id) =>
    "cloud provider '$id' will not see your tasks until sharing is on";

/// The warning for selecting [provider] under [policy], or null when
/// there is nothing to warn about.
String? selectionWarning(LlmProvider provider, PrivacyPolicy policy) =>
    policy.withholdsFrom(provider.privacy)
    ? cloudSelectionWarning(provider.id)
    : null;
