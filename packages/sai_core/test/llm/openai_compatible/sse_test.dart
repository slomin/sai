import 'dart:convert';

import 'package:sai_core/src/llm/openai_compatible/chunks.dart';
import 'package:sai_core/src/llm/openai_compatible/sse.dart';
import 'package:test/test.dart';

Future<List<String>> frame(List<String> chunks) =>
    Stream.fromIterable(chunks.map(utf8.encode))
        .transform(sseEvents())
        .where((e) => !e.comment)
        .map((e) => e.data)
        .toList();

void main() {
  group('sseEvents', () {
    test('frames data lines on blank lines, LF or CRLF', () async {
      expect(await frame(['data: a\n\ndata: b\r\n\r\n']), ['a', 'b']);
    });

    test('joins multi-line data, drops comments and other fields', () async {
      expect(await frame([': ping\nevent: x\ndata: 1\ndata:2\n\n']), ['1\n2']);
    });

    test('is independent of how the bytes are chunked', () async {
      const text = 'data: {"a":"héllo"}\n\ndata: [DONE]\n\n';
      final bytes = utf8.encode(text);
      for (final size in [1, 2, 3, 7, 64]) {
        final events = await Stream<List<int>>.fromIterable([
          for (var i = 0; i < bytes.length; i += size)
            bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size),
        ]).transform(sseEvents()).map((e) => e.data).toList();
        expect(events, ['{"a":"héllo"}', '[DONE]'], reason: 'size $size');
      }
    });

    test('an event open at end of stream is still delivered', () async {
      expect(await frame(['data: a\n\ndata: [DONE]']), ['a', '[DONE]']);
      final last = await Stream.fromIterable([utf8.encode('data: [DONE]')])
          .transform(sseEvents())
          .last;
      expect(last.isDone, isTrue);
    });

    test('nothing is nothing; a comment is a keep-alive', () async {
      expect(await frame(['']), isEmpty);
      expect(await frame([': only comments\n\n']), isEmpty);
      final all = await Stream<List<int>>.fromIterable([
        utf8.encode(': ping\n: pong\ndata: [DONE]\n\n'),
      ]).transform(sseEvents()).toList();
      expect(all.map((e) => e.comment), [true, true, false]);
      expect(all.last.isDone, isTrue);
    });
  });

  group('ChatChunk.parse', () {
    test('reads a content delta', () {
      final c = ChatChunk.parse(
        '{"id":"chatcmpl-1","model":"m","choices":[{"index":0,'
        '"delta":{"content":"hi"},"finish_reason":null}]}',
      );
      expect(c.id, 'chatcmpl-1');
      expect(c.model, 'm');
      expect(c.content, 'hi');
      expect(c.finishReason, isNull);
      expect(c.usage, isNull);
    });

    test('leaves reasoning out, reads the finish reason', () {
      final r = ChatChunk.parse(
        '{"choices":[{"delta":{"reasoning_content":"hmm"},"finish_reason":null}]}',
      );
      expect(r.content, isNull);
      final f = ChatChunk.parse(
        '{"choices":[{"delta":{},"finish_reason":"length"}]}',
      );
      expect(f.finishReason, 'length');
    });

    test('reads usage with empty choices, and llama.cpp timings', () {
      final u = ChatChunk.parse(
        '{"choices":[],"usage":{"prompt_tokens":18,"completion_tokens":117,'
        '"total_tokens":135,"completion_tokens_details":{"reasoning_tokens":113}}}',
      );
      expect(u.usage!.promptTokens, 18);
      expect(u.usage!.completionTokens, 117);
      expect(u.usage!.totalTokens, 135);
      final t = ChatChunk.parse(
        '{"choices":[{"delta":{},"finish_reason":"stop"}],'
        '"timings":{"predicted_per_second":52.94,"prompt_n":1}}',
      );
      expect(t.tokensPerSecond, 52.94);
      expect(t.finishReason, 'stop');
    });

    test('refuses what is not a JSON object, without quoting it', () {
      for (final bad in ['nope', '[1]', '"sk-secret"', '{']) {
        expect(
          () => ChatChunk.parse(bad),
          throwsA(
            isA<FormatException>().having(
              (e) => e.toString(),
              'text',
              isNot(contains('sk-')),
            ),
          ),
          reason: bad,
        );
      }
      // Odd but readable shapes are tolerated as empty chunks.
      expect(ChatChunk.parse('{}').content, isNull);
      expect(ChatChunk.parse('{"choices":"x"}').finishReason, isNull);
    });
  });
}
