/// Applying an accepted suggestion (#35) — the one production call
/// site of `Attribution.assistant`, pinned by
/// `test/no_assistant_mutation_test.dart`. Everything goes through the
/// store's ordinary commands: an accepted change is validated, event-
/// sourced and undoable like any other, attributed to the model that
/// proposed it with `refs` naming the proposal and the acceptance.
library;

import '../archive/blobref.dart';
import '../tasks/events.dart';
import '../tasks/model.dart';
import '../tasks/store.dart';
import 'proposal.dart';

Future<void> applySuggestion(
  Suggestion suggestion, {
  required TaskStore store,
  required Proposal proposal,
  required BlobRef accept,
}) async {
  final by = Attribution.assistant(
    proposal.model,
    refs: [proposal.event, accept],
  );
  switch (suggestion.kind) {
    case SuggestionKind.schedule:
      await store.editTask(
        suggestion.target,
        when: Patch(suggestion.when!),
        by: by,
      );
    case SuggestionKind.deadline:
      await store.editTask(
        suggestion.target,
        deadline: Patch(suggestion.deadline),
        by: by,
      );
    case SuggestionKind.split:
      await store.splitTask(suggestion.target, suggestion.parts, by: by);
  }
}
