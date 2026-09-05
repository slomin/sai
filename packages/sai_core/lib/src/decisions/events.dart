/// The decision family (#14): what the person who keeps this sai decided
/// on her behalf — the name, the model, the memory — recorded so a later
/// sai can read the reasoning and revise it. Additive: no projection
/// applies these lines, and the registry table in
/// `docs/archive/event-log-v0.md` grows in the same change
/// (`test/decisions/registry_test.dart` pins it).
library;

import '../archive/event.dart';
import 'decision.dart';

abstract final class DecisionEventTypes {
  /// One decision, actor `user` — the guardian, not the assistant. The
  /// payload is a [Decision]; a revision is a new line, never an edit.
  static const made = 'decision.made';

  static const all = [made];
}

/// The `decision.made` line for [decision], recorded by [source]. No
/// `model` — no model took part — and no `refs`: the log holds the
/// decision itself, and a later one that revises it says so in words.
EventDraft decisionMadeDraft(Decision decision, {required String source}) =>
    EventDraft(
      type: DecisionEventTypes.made,
      actor: Actor.user,
      source: source,
      payload: decision.toPayload(),
    );
