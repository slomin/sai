import 'dart:convert';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  final decision = Decision(
    title: 'Name and pronoun',
    decided: const CalendarDate(2026, 8, 23),
    by: 'the guardian',
    decision: 'She is called sai.',
    alternatives: const ['it', 'they'],
    reasoning: 'A name is needed before the first conversation.',
  );

  test('decision.made seals as a user event with no model and no refs', () {
    final draft = decisionMadeDraft(decision, source: 'sai/test');
    final sealed = Event.seal(draft, prev: null);
    expect(sealed.type, 'decision.made');
    expect(sealed.actor, Actor.user);
    expect(sealed.model, isNull);
    expect(sealed.refs, isEmpty);
    expect(sealed.source, 'sai/test');
    expect(sealed.payload, {
      'title': 'Name and pronoun',
      'decided': '2026-08-23',
      'by': 'the guardian',
      'decision': 'She is called sai.',
      'alternatives': ['it', 'they'],
      'reasoning': 'A name is needed before the first conversation.',
    });
    // The line round-trips like any other event, without a refs key.
    final line = sealed.encode();
    expect(line, isNot(contains('"refs"')));
    expect(line, isNot(contains('"model"')));
    final decoded = Event.decodeLine(line);
    expect(decoded.type, DecisionEventTypes.made);
    expect(Decision.fromPayload(decoded.payload), decision);
  });

  test('a profile decision names the file it created', () {
    final id = BlobRef.sha256OfBytes(utf8.encode('profile'));
    final draft = decisionMadeDraft(
      Decision(
        title: 'Profile v0',
        decided: const CalendarDate(2026, 9, 5),
        by: 'the guardian',
        decision: 'A written profile.',
        reasoning: 'So she can be read.',
        profile: id,
      ),
      source: 'sai/test',
    );
    expect(draft.payload['profile'], {'id': id.toString()});
    expect(draft.payload['alternatives'], isEmpty);
    final sealed = Event.seal(draft, prev: null);
    expect(Decision.fromPayload(sealed.payload).profile, id);
  });
}
