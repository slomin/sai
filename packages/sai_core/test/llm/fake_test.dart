import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

import 'provider_contract.dart';

LlmRequest ask(String text, {int? maxTokens}) => LlmRequest(
  messages: [
    const LlmMessage(LlmRole.system, 'be brief'),
    LlmMessage(LlmRole.user, text),
  ],
  maxTokens: maxTokens,
);

void main() {
  llmProviderContract(
    'FakeLlmProvider',
    FakeLlmProvider.new,
    request: () => ask('one two three'),
  );

  group('FakeLlmProvider', () {
    test('describes itself as a local fake', () {
      final fake = FakeLlmProvider();
      expect(fake.id, 'fake');
      expect(fake.displayName, 'fake');
      expect(fake.privacy, LlmPrivacy.local);
      expect(fake.defaultModel, 'fake-1');
    });

    test('echoes the last user message word by word by default', () async {
      final call = FakeLlmProvider().start(ask('hello there world'));
      final deltas = await call.deltas.map((d) => d.text).toList();
      expect(deltas, ['hello ', 'there ', 'world']);
      final result = await call.done;
      expect(result.text, 'hello there world');
      expect(result.usage?.promptTokens, 5);
      expect(result.usage?.completionTokens, 3);
      expect(result.usage?.totalTokens, 8);
    });

    test('a script decides the reply', () async {
      final fake = FakeLlmProvider(
        script: (request) => 'you said ${request.messages.last.text}',
      );
      expect((await fake.start(ask('hi')).done).text, 'you said hi');
    });

    test('lineage names the fake and numbers its requests', () async {
      final fake = FakeLlmProvider();
      final first = await fake.start(ask('a')).done;
      final second = await fake.start(ask('b')).done;
      expect(first.model.provider, 'fake');
      expect(first.model.id, 'fake-1');
      expect(first.model.version, 'fake-1');
      expect(first.model.requestId, 'fake-req-1');
      expect(second.model.requestId, 'fake-req-2');
    });

    test('max_tokens cuts the reply and finishes with length', () async {
      final result = await FakeLlmProvider()
          .start(ask('one two three four', maxTokens: 2))
          .done;
      expect(result.text, 'one two ');
      expect(result.finish, LlmFinish.length);
      expect(result.usage?.completionTokens, 2);
    });

    test('an injected failure lands on done, after failAfter deltas', () async {
      const failure = LlmFailure(LlmFailureKind.timeout, 'fake timeout');
      final fake = FakeLlmProvider(failWith: failure, failAfter: 1);
      final call = fake.start(ask('one two three'));
      final deltas = await call.deltas.map((d) => d.text).toList();
      final result = await call.done;
      expect(deltas, ['one ']);
      expect(result.finish, LlmFinish.failed);
      expect(result.text, 'one ');
      expect(result.failure, same(failure));
    });

    test('an injected failure with no deltas is still a failure', () async {
      const failure = LlmFailure(LlmFailureKind.unreachable, 'down');
      final result = await FakeLlmProvider(failWith: failure)
          .start(ask('x'))
          .done;
      expect(result.finish, LlmFinish.failed);
      expect(result.text, isEmpty);
    });

    test('a real delta interval paces the stream', () async {
      final fake = FakeLlmProvider(delta: const Duration(milliseconds: 5));
      final started = DateTime.now();
      await fake.start(ask('a b c')).done;
      expect(
        DateTime.now().difference(started).inMilliseconds,
        greaterThanOrEqualTo(10),
      );
    });
  });
}
