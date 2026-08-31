/// The proposal event family (#35). Additive: the task projection
/// counts these lines and applies none, no reader is required to know
/// them, and the registry table in `docs/archive/event-log-v0.md` grows
/// in the same change (`test/proposals/registry_test.dart` pins it).
library;

import '../archive/blobref.dart';
import '../archive/event.dart';
import 'proposal.dart';
import 'schema.dart';

abstract final class ProposalEventTypes {
  /// The validated suggestions, ids resolved, actor `assistant`.
  static const made = 'proposal.made';

  /// The person accepted one item; written before the mutation.
  static const accept = 'proposal.accept';

  /// The person rejected one item.
  static const reject = 'proposal.reject';

  /// A proposal call whose output failed validation, actor `system`.
  static const refused = 'proposal.refused';

  static const all = [made, accept, reject, refused];
}

/// The `proposal.made` line: [refs] names the `provider.response` that
/// carried the output and the `chat.message` that triggered the call.
EventDraft proposalMadeDraft({
  required String note,
  required List<Suggestion> items,
  required ModelRef model,
  required String source,
  required List<BlobRef> refs,
}) => EventDraft(
  type: ProposalEventTypes.made,
  actor: Actor.assistant,
  source: source,
  payload: {
    'schema': proposalSchemaVersion,
    'note': note,
    'items': [for (final item in items) item.toEventJson()],
  },
  model: model,
  refs: refs,
);

/// The person's word on item [item] of [proposal]: `proposal.accept`
/// or `proposal.reject`, actor `user`, `refs` → the `proposal.made`.
EventDraft proposalVerdictDraft(
  String type, {
  required BlobRef proposal,
  required int item,
  required String source,
}) {
  assert(
    type == ProposalEventTypes.accept || type == ProposalEventTypes.reject,
  );
  return EventDraft(
    type: type,
    actor: Actor.user,
    source: source,
    payload: {'item': item},
    refs: [proposal],
  );
}

/// A proposal call that produced no proposal: `payload.reason` is the
/// fixed validation text, `refs` → the `provider.response`.
EventDraft proposalRefusedDraft({
  required String reason,
  required BlobRef response,
  required String source,
}) => EventDraft(
  type: ProposalEventTypes.refused,
  actor: Actor.system,
  source: source,
  payload: {'reason': reason},
  refs: [response],
);
