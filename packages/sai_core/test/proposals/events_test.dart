import 'dart:convert';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  final response = BlobRef.sha256OfBytes(utf8.encode('response'));
  final made = BlobRef.sha256OfBytes(utf8.encode('made'));
  final said = BlobRef.sha256OfBytes(utf8.encode('said'));
  const model = ModelRef(provider: 'fake', id: 'fake-1');
  final target = BlobRef.sha256OfBytes(utf8.encode('task'));

  Suggestion suggestion({
    SuggestionKind kind = SuggestionKind.schedule,
    TaskWhen? when = TaskWhen.someday,
    CalendarDate? deadline,
    List<String> parts = const [],
  }) => Suggestion(
    index: 0,
    kind: kind,
    target: target,
    targetTitle: 'Buy milk',
    fingerprint: DateTime.utc(2026, 8, 25, 8),
    when: when,
    deadline: deadline,
    parts: parts,
    reason: 'because',
  );

  test('proposal.made seals as an assistant event with the model', () {
    final draft = proposalMadeDraft(
      note: 'two ideas',
      items: [
        suggestion(),
        suggestion(kind: SuggestionKind.split, when: null, parts: ['a', 'b']),
      ],
      model: model,
      source: 'sai/test',
      refs: [response, said],
    );
    final sealed = Event.seal(draft, prev: null);
    expect(sealed.type, 'proposal.made');
    expect(sealed.actor, Actor.assistant);
    expect(sealed.model?.provider, 'fake');
    expect(sealed.refs, [response, said]);
    expect(sealed.payload['schema'], proposalSchemaVersion);
    expect(sealed.payload['note'], 'two ideas');
    final items = (sealed.payload['items'] as List).cast<Map>();
    expect(items[0], {
      'kind': 'schedule',
      'task': target.toString(),
      'when': 'someday',
      'reason': 'because',
    });
    expect(items[1], {
      'kind': 'split',
      'task': target.toString(),
      'parts': ['a', 'b'],
      'reason': 'because',
    });
    // The line round-trips like any other event.
    final decoded = Event.decodeLine(sealed.encode());
    expect(decoded.type, 'proposal.made');
  });

  test('an anytime schedule records when as null, a clear likewise', () {
    final draft = proposalMadeDraft(
      note: '',
      items: [
        suggestion(when: TaskWhen.none),
        suggestion(kind: SuggestionKind.deadline, when: null),
      ],
      model: model,
      source: 'sai/test',
      refs: [response],
    );
    final items = (draft.payload['items'] as List).cast<Map>();
    expect(items[0].containsKey('when'), isTrue);
    expect(items[0]['when'], isNull);
    expect(items[1]['deadline'], isNull);
  });

  test('accept and reject are user verdicts naming the proposal', () {
    for (final type in [ProposalEventTypes.accept, ProposalEventTypes.reject]) {
      final sealed = Event.seal(
        proposalVerdictDraft(type, proposal: made, item: 1, source: 'sai/test'),
        prev: null,
      );
      expect(sealed.type, type);
      expect(sealed.actor, Actor.user);
      expect(sealed.model, isNull);
      expect(sealed.refs, [made]);
      expect(sealed.payload, {'item': 1});
    }
  });

  test('proposal.refused is a system line naming the response', () {
    final sealed = Event.seal(
      proposalRefusedDraft(
        reason: 'not JSON',
        response: response,
        source: 'sai/test',
      ),
      prev: null,
    );
    expect(sealed.actor, Actor.system);
    expect(sealed.refs, [response]);
    expect(sealed.payload, {'reason': 'not JSON'});
  });
}
