import 'dart:convert';

import 'package:sai_core/src/llm/openai/events.dart';
import 'package:test/test.dart';

void main() {
  ResponsesEvent parse(Map<String, Object?> data) =>
      ResponsesEvent.parse(jsonEncode(data));

  test('text and reasoning-summary deltas are told apart by type', () {
    final text = parse({
      'type': 'response.output_text.delta',
      'item_id': 'msg_1',
      'delta': 'hel',
      'sequence_number': 3,
    });
    expect(text.kind, ResponsesEventKind.text);
    expect(text.delta, 'hel');
    final thought = parse({
      'type': 'response.reasoning_summary_text.delta',
      'item_id': 'rs_1',
      'summary_index': 0,
      'delta': 'thinking',
    });
    expect(thought.kind, ResponsesEventKind.reasoning);
    expect(thought.delta, 'thinking');
  });

  test('the terminal response carries the model, the id and the usage', () {
    final done = parse({
      'type': 'response.completed',
      'response': {
        'id': 'resp_1',
        'model': 'gpt-5.6-sol-2026-08-01',
        'status': 'completed',
        'usage': {
          'input_tokens': 81,
          'output_tokens': 1035,
          'total_tokens': 1116,
          'output_tokens_details': {'reasoning_tokens': 832},
        },
      },
    });
    expect(done.kind, ResponsesEventKind.completed);
    expect(done.model, 'gpt-5.6-sol-2026-08-01');
    expect(done.responseId, 'resp_1');
    expect(done.usage?.promptTokens, 81);
    expect(done.usage?.completionTokens, 1035);
    expect(done.usage?.totalTokens, 1116);
    expect(done.usage?.cost, isNull, reason: 'never estimated');
    final cut = parse({
      'type': 'response.incomplete',
      'response': {
        'id': 'resp_2',
        'model': 'm',
        'incomplete_details': {'reason': 'max_output_tokens'},
        'usage': null,
      },
    });
    expect(cut.kind, ResponsesEventKind.incomplete);
    expect(cut.incompleteReason, 'max_output_tokens');
    expect(cut.usage, isNull);
  });

  test(
    'a failure is a failure whichever event says it; its text is dropped',
    () {
      final failed = parse({
        'type': 'response.failed',
        'response': {
          'error': {'code': 'server_error', 'message': 'sk-canary quoted'},
        },
      });
      expect(failed.kind, ResponsesEventKind.failed);
      final error = parse({
        'type': 'error',
        'code': 'rate_limit',
        'message': 'sk-canary quoted',
      });
      expect(error.kind, ResponsesEventKind.failed);
      expect('$failed$error', isNot(contains('sk-canary')));
    },
  );

  test('an output item that is not a message or reasoning fails closed', () {
    for (final passive in ['message', 'reasoning']) {
      expect(
        parse({
          'type': 'response.output_item.added',
          'item': {'type': passive, 'id': 'x'},
        }).kind,
        ResponsesEventKind.other,
        reason: passive,
      );
    }
    for (final active in [
      'function_call',
      'web_search_call',
      'file_search_call',
      'computer_call',
      'code_interpreter_call',
      'image_generation_call',
      'mcp_call',
      'custom_tool_call',
    ]) {
      expect(
        parse({
          'type': 'response.output_item.added',
          'item': {'type': active, 'id': 'x'},
        }).kind,
        ResponsesEventKind.unexpectedItem,
        reason: active,
      );
    }
    expect(
      parse({'type': 'response.output_item.added'}).kind,
      ResponsesEventKind.unexpectedItem,
      reason: 'an item with no type is not one sai asked for',
    );
  });

  test('lifecycle markers and unknown types are passive', () {
    for (final type in [
      'response.created',
      'response.in_progress',
      'response.output_item.done',
      'response.content_part.added',
      'response.content_part.done',
      'response.output_text.done',
      'response.reasoning_summary_part.added',
      'response.something.from.the.future',
    ]) {
      expect(
        parse({'type': type}).kind,
        ResponsesEventKind.other,
        reason: type,
      );
    }
  });

  test('what is not an event with a type is a format error', () {
    expect(() => ResponsesEvent.parse('not json'), throwsFormatException);
    expect(() => ResponsesEvent.parse('[]'), throwsFormatException);
    expect(() => ResponsesEvent.parse('{"delta":"x"}'), throwsFormatException);
    expect(() => ResponsesEvent.parse('{"type":3}'), throwsFormatException);
  });
}
