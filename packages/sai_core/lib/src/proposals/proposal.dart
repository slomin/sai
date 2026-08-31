/// The proposal model (#35): validated suggestions the person may
/// accept or reject, one at a time. Session state — the archive holds
/// the record (`proposal.*` lines), the lane holds only the latest
/// proposal, and nothing here mutates anything.
library;

import '../archive/blobref.dart';
import '../archive/event.dart';
import '../tasks/date.dart';
import '../tasks/model.dart';
import '../tasks/projection.dart';

enum SuggestionKind { schedule, deadline, split }

enum SuggestionStatus { pending, accepted, rejected, failed }

/// One suggested change, resolved to a real task at validation time.
/// [fingerprint] is the target's `modifiedAt` as the model saw it: any
/// later mutation makes the suggestion [stale], and a stale suggestion
/// is surfaced, never applied.
final class Suggestion {
  Suggestion({
    required this.index,
    required this.kind,
    required this.target,
    required this.targetTitle,
    required this.fingerprint,
    this.when,
    this.deadline,
    List<String> parts = const [],
    required this.reason,
    this.status = SuggestionStatus.pending,
    this.failure,
  }) : parts = List.unmodifiable(parts);

  /// Position in the proposal's `items`, and in `payload.item` on the
  /// accept and reject lines.
  final int index;

  final SuggestionKind kind;
  final TaskId target;

  /// The target's title as it stood at proposal time, for display.
  final String targetTitle;

  /// The target's `modifiedAt` at proposal time.
  final DateTime fingerprint;

  /// The new plan, for [SuggestionKind.schedule].
  final TaskWhen? when;

  /// The new deadline, for [SuggestionKind.deadline]; null clears it.
  final CalendarDate? deadline;

  /// The new titles, for [SuggestionKind.split].
  final List<String> parts;

  final String reason;
  final SuggestionStatus status;

  /// Why applying failed, when [status] is [SuggestionStatus.failed].
  final String? failure;

  /// Whether the target changed since the proposal: gone, deleted, no
  /// longer open, or mutated (every task mutation bumps `modifiedAt`).
  bool stale(TaskProjection projection) {
    final task = projection.task(target);
    return task == null ||
        task.deletedAt != null ||
        task.status != TaskStatus.open ||
        task.modifiedAt != fingerprint;
  }

  /// The card's first line, shared by both clients.
  String get headline => switch (kind) {
    SuggestionKind.schedule => switch (when!) {
      TaskWhenNone() => 'Move to Anytime',
      TaskWhenSomeday() => 'Move to Someday',
      TaskWhenDate(:final date) => 'Schedule for $date',
    },
    SuggestionKind.deadline =>
      deadline == null ? 'Clear the deadline' : 'Deadline $deadline',
    SuggestionKind.split => 'Split into ${parts.length}',
  };

  Suggestion withStatus(SuggestionStatus status, {String? failure}) =>
      Suggestion(
        index: index,
        kind: kind,
        target: target,
        targetTitle: targetTitle,
        fingerprint: fingerprint,
        when: when,
        deadline: deadline,
        parts: parts,
        reason: reason,
        status: status,
        failure: failure,
      );

  /// The item as `proposal.made` records it: the task by id — handles
  /// are turn-local and never persisted — and only the field its kind
  /// reads.
  Map<String, Object?> toEventJson() => {
    'kind': kind.name,
    'task': target.toString(),
    switch (kind) {
      SuggestionKind.schedule => 'when',
      SuggestionKind.deadline => 'deadline',
      SuggestionKind.split => 'parts',
    }: switch (kind) {
      SuggestionKind.schedule => when!.toJson(),
      SuggestionKind.deadline => deadline?.toString(),
      SuggestionKind.split => parts,
    },
    'reason': reason,
  };
}

/// A validated proposal before its `proposal.made` line exists.
final class ParsedProposal {
  ParsedProposal({required this.note, required List<Suggestion> items})
    : items = List.unmodifiable(items);

  final String note;
  final List<Suggestion> items;
}

/// The lane's unit: a recorded proposal and its items.
final class Proposal {
  Proposal({
    required this.event,
    required this.model,
    required this.note,
    required List<Suggestion> items,
  }) : items = List.unmodifiable(items);

  /// The `proposal.made` line's id.
  final BlobRef event;

  /// The model that proposed, carried onto every applied mutation.
  final ModelRef model;

  final String note;
  final List<Suggestion> items;

  Proposal withItem(int index, Suggestion item) => Proposal(
    event: event,
    model: model,
    note: note,
    items: [
      for (final existing in items)
        if (existing.index == index) item else existing,
    ],
  );
}

/// How a proposal call ended, hung onto the turn that triggered it.
sealed class ProposalOutcome {
  const ProposalOutcome();
}

/// A `proposal.made` line exists and the lane shows [count] items.
final class ProposalMade extends ProposalOutcome {
  const ProposalMade({
    required this.event,
    required this.count,
    required this.note,
  });

  final BlobRef event;
  final int count;
  final String note;
}

/// The call produced no proposal: cancelled, failed, or output that
/// did not validate. [reason] is what the turn note explains.
final class ProposalRefused extends ProposalOutcome {
  const ProposalRefused(this.reason);

  final String reason;
}
