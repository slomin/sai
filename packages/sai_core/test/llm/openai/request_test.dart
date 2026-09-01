import 'package:sai_core/sai_core.dart';
import 'package:sai_core/src/llm/openai/request.dart';
import 'package:test/test.dart';

void main() {
  final messages = [
    const LlmMessage(LlmRole.system, 'be brief'),
    const LlmMessage(LlmRole.user, 'earlier'),
    const LlmMessage(LlmRole.assistant, 'then'),
    const LlmMessage(LlmRole.user, 'now'),
  ];

  test('every message goes as one input item, in order, by role', () {
    final body = responsesBody(
      LlmRequest(messages: messages),
      model: 'gpt-5.6-sol',
    );
    expect(body['model'], 'gpt-5.6-sol');
    expect(body['input'], [
      {'role': 'developer', 'content': 'be brief'},
      {'role': 'user', 'content': 'earlier'},
      {'role': 'assistant', 'content': 'then'},
      {'role': 'user', 'content': 'now'},
    ]);
    expect(body, isNot(contains('instructions')));
  });

  test('streamed, stored nowhere, no tools, no conversation, no metadata', () {
    final body = responsesBody(
      LlmRequest(messages: messages),
      model: 'gpt-5.6-sol',
    );
    expect(body['stream'], isTrue);
    expect(body['store'], isFalse);
    expect(body['background'], isFalse);
    expect(body['tools'], isEmpty);
    expect(body['tool_choice'], 'none');
    for (final absent in [
      'previous_response_id',
      'conversation',
      'metadata',
      'max_tokens',
      'messages',
      'temperature',
      'reasoning',
      'text',
    ]) {
      expect(body, isNot(contains(absent)), reason: absent);
    }
  });

  test('the effort goes exactly as chosen; Model default sends none', () {
    Map<String, Object?> at(ReasoningEffort? effort) => responsesBody(
      LlmRequest(messages: messages, reasoningEffort: effort),
      model: 'm',
    );
    expect(at(null), isNot(contains('reasoning')));
    expect(at(ReasoningEffort.none)['reasoning'], {'effort': 'none'});
    for (final word in openAiEffortWords) {
      expect(at(ReasoningEffort(word))['reasoning'], {'effort': word});
    }
    expect(at(const ReasoningEffort('ultra'))['reasoning'], {
      'effort': 'ultra',
    }, reason: 'an unknown word is the model\'s to refuse, not sai\'s');
  });

  test('max_tokens is max_output_tokens; temperature only when set', () {
    final body = responsesBody(
      LlmRequest(messages: messages, maxTokens: 512, temperature: 0),
      model: 'm',
    );
    expect(body['max_output_tokens'], 512);
    expect(body['temperature'], 0);
    expect(body, isNot(contains('max_tokens')));
  });

  test('a response schema is the strict text.format', () {
    final body = responsesBody(
      LlmRequest(
        messages: messages,
        responseSchema: const ResponseSchema(
          name: 'proposal',
          schema: {'type': 'object'},
        ),
      ),
      model: 'm',
    );
    expect(body['text'], {
      'format': {
        'type': 'json_schema',
        'name': 'proposal',
        'strict': true,
        'schema': {'type': 'object'},
      },
    });
    expect(body, isNot(contains('response_format')));
  });

  test('the same request gives the same body', () {
    final a = responsesBody(
      LlmRequest(messages: messages, reasoningEffort: ReasoningEffort.none),
      model: 'm',
    );
    final b = responsesBody(
      LlmRequest(messages: messages, reasoningEffort: ReasoningEffort.none),
      model: 'm',
    );
    expect(a, b);
  });
}
