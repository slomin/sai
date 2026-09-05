import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  const today = CalendarDate(2026, 8, 25);
  final projection = TaskProjection.empty;

  AssembledContext proposal() => assembleProposal(
    profile: assistantProfile,
    projection: projection,
    today: today,
    history: const [],
    request: defaultProposalRequest,
  );

  test('the proposal prefix is byte-identical to the warm-up', () {
    final sent = proposal().request.sent;
    final warm = assembleWarmup(
      profile: assistantProfile,
      projection: projection,
      today: today,
    ).sent;
    expect(sent[0].role, LlmRole.system);
    expect(sent[1].role, LlmRole.system);
    expect(sent[0].text, warm[0].text);
    expect(sent[1].text, warm[1].text, reason: 'the cached prefix must serve');
  });

  test('the schema rides the request and is measured up front', () {
    final request = proposal().request;
    expect(request.responseSchema, same(proposalResponseSchema));
    final bare = assembleContext(
      profile: assistantProfile,
      projection: projection,
      today: today,
      history: const [],
      draft: proposalInstruction(defaultProposalRequest),
      shape: TaskContextShape.catalog,
    );
    expect(
      recordedRequestBytes(request),
      greaterThan(recordedRequestBytes(bare.request)),
      reason: 'the preflight must count the recorded response_format',
    );
  });

  test('the instruction carries the request and the vocabulary', () {
    final text = proposalInstruction('drop something');
    expect(text, contains('Request: drop something'));
    expect(text, contains('someday'));
    expect(text, contains('split'));
  });
}
