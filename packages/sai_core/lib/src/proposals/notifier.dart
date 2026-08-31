/// The lane's state (#35): the latest proposal and the person's
/// verdicts on its items. Session-local — a new proposal replaces the
/// last, and the archive keeps the record.
library;

import 'package:riverpod/riverpod.dart';

import '../archive/archive.dart';
import '../providers.dart';
import '../tasks/projection.dart';
import 'apply.dart';
import 'events.dart';
import 'proposal.dart';

/// Accept refused because the target changed since the proposal.
const staleSuggestion = 'this suggestion is stale — the task changed';

/// A verdict on an item that is no longer pending.
const suggestionSettled = 'already settled';

/// A verdict while the item's previous verdict is still applying.
const suggestionBusy = 'still applying';

final class ProposalsState {
  const ProposalsState({this.current});

  /// The proposal the lane shows, or null for no lane.
  final Proposal? current;
}

/// One suggestion as a client renders it: [stale] is derived against
/// the live projection, so both clients re-derive it whenever the
/// tasks change (the app's watch, the TUI's two-second reload).
final class SuggestionView {
  const SuggestionView({required this.item, required this.stale});

  final Suggestion item;
  final bool stale;
}

class ProposalsNotifier extends Notifier<ProposalsState> {
  final _applying = <int>{};

  @override
  ProposalsState build() => const ProposalsState();

  /// Shows [proposal] in the lane, replacing the previous one — its
  /// pending items simply leave the lane; nothing happened, nothing is
  /// written.
  void offer(Proposal proposal) => state = ProposalsState(current: proposal);

  void clear() => state = const ProposalsState();

  /// Accepts item [index]: writes `proposal.accept`, then applies the
  /// change through the store as the assistant. Returns null on
  /// success, or the refusal sentence for the client's notice. A stale
  /// item refuses before anything is written; a store refusal after
  /// the accept line marks the item failed — the log stays honest
  /// either way.
  Future<String?> accept(int index) => _verdict(index, accepting: true);

  /// Rejects item [index]: writes `proposal.reject` and settles it.
  Future<String?> reject(int index) => _verdict(index, accepting: false);

  Future<String?> _verdict(int index, {required bool accepting}) async {
    final container = ref.container;
    final proposal = state.current;
    if (proposal == null || index < 0 || index >= proposal.items.length) {
      return 'no such suggestion';
    }
    final item = proposal.items[index];
    if (item.status != SuggestionStatus.pending) return suggestionSettled;
    if (!_applying.add(index)) return suggestionBusy;
    try {
      final projection = container.read(tasksProvider).value;
      if (projection == null) return 'the tasks are not open yet';
      if (accepting && item.stale(projection)) return staleSuggestion;

      final Archive archive;
      final StoredEvent verdict;
      try {
        archive = await container.read(archiveProvider.future);
        verdict = await archive.append(
          proposalVerdictDraft(
            accepting ? ProposalEventTypes.accept : ProposalEventTypes.reject,
            proposal: proposal.event,
            item: index,
            source: container.read(eventSourceProvider),
          ),
        );
      } on Object catch (error) {
        return 'could not record the verdict: $error';
      }
      container.read(archiveRevisionProvider.notifier).bump();

      if (!accepting) {
        _settle(proposal, item.withStatus(SuggestionStatus.rejected));
        return null;
      }
      try {
        await applySuggestion(
          item,
          store: container.read(tasksProvider.notifier).store,
          proposal: proposal,
          accept: verdict.id,
        );
      } on Object catch (error) {
        final reason = _describe(error);
        _settle(
          proposal,
          item.withStatus(SuggestionStatus.failed, failure: reason),
        );
        return 'accept failed: $reason';
      }
      container.read(archiveRevisionProvider.notifier).bump();
      _settle(proposal, item.withStatus(SuggestionStatus.accepted));
      return null;
    } finally {
      _applying.remove(index);
    }
  }

  /// Applies a settled item onto the state — unless a newer proposal
  /// replaced [proposal] while the verdict was in flight.
  void _settle(Proposal proposal, Suggestion item) {
    final current = state.current;
    if (current == null || current.event != proposal.event) return;
    state = ProposalsState(current: current.withItem(item.index, item));
  }
}

String _describe(Object error) => switch (error) {
  TaskProjectionError(:final reason) => reason,
  ArgumentError(:final message?) => '$message',
  StateError(:final message) => message,
  _ => '$error',
};
