import 'dart:convert';

import 'package:riverpod/riverpod.dart';
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
  test('the lorem fake streams lorem ipsum, not the prompt', () async {
    final fake = FakeLlmProvider.lorem(words: 5, delta: Duration.zero);
    final result = await fake.start(ask('hello')).done;
    expect(result.text, 'Lorem ipsum dolor sit amet,');
    expect(loremIpsum(70).split(' '), hasLength(70));
  });

  group('the built-in fake (#99)', () {
    test('streams at once unless the environment asks for a pause', () {
      expect(fakeDeltaFrom(const {}), Duration.zero);
      expect(
        fakeDeltaFrom(const {'SAI_FAKE_DELTA_MS': '60'}),
        const Duration(milliseconds: 60),
      );
      expect(fakeDeltaFrom(const {'SAI_FAKE_DELTA_MS': 'slow'}), Duration.zero);
      expect(fakeDeltaFrom(const {'SAI_FAKE_DELTA_MS': '-5'}), Duration.zero);
    });

    test('is built with the delta the environment names', () {
      final container = ProviderContainer(
        overrides: [
          environmentProvider.overrideWithValue(const {
            'SAI_FAKE_DELTA_MS': '60',
          }),
          secretStoreProvider.overrideWithValue(InMemorySecretStore()),
        ],
      );
      addTearDown(container.dispose);
      final fake =
          container.read(builtinLlmsProvider).first() as FakeLlmProvider;
      expect(fake.delta, const Duration(milliseconds: 60));
      final plain =
          builtinLlms(InMemorySecretStore()).first() as FakeLlmProvider;
      expect(plain.delta, Duration.zero);
    });
  });

  llmProviderContract(
    'FakeLlmProvider',
    FakeLlmProvider.new,
    request: () => ask('one two three'),
  );

  group('the canned proposal (#35)', () {
    const schema = ResponseSchema(name: 'p', schema: {'type': 'object'});

    LlmRequest propose(String catalog) => LlmRequest(
      messages: [
        const LlmMessage(LlmRole.system, 'profile'),
        LlmMessage(LlmRole.system, catalog),
        const LlmMessage(LlmRole.user, 'propose'),
      ],
      responseSchema: schema,
    );

    test('a schema request gets one suggestion per known kind', () async {
      final result = await FakeLlmProvider()
          .start(
            propose(
              'Open (3):\n'
              '- [t1] Buy milk @today\n'
              '- [t2] Loose thought\n'
              '- [t3] Dream trip\n',
            ),
          )
          .done;
      final decoded = jsonDecode(result.text) as Map<String, Object?>;
      expect(decoded['note'], 'fake suggestions');
      final suggestions = (decoded['suggestions'] as List).cast<Map>();
      expect(suggestions, hasLength(3));
      expect(suggestions[0]['kind'], 'schedule');
      expect(suggestions[0]['task'], 't1');
      expect(suggestions[0]['when'], 'someday');
      expect(suggestions[1]['kind'], 'deadline');
      expect(suggestions[1]['task'], 't2');
      expect(suggestions[1]['deadline'], 'tomorrow');
      expect(suggestions[2]['kind'], 'split');
      expect(suggestions[2]['task'], 't3');
      expect((suggestions[2]['parts'] as List).length, 2);
    });

    test('fewer handles mean fewer suggestions', () async {
      final result = await FakeLlmProvider()
          .start(propose('Open (1):\n- [t1] Buy milk\n'))
          .done;
      final decoded = jsonDecode(result.text) as Map<String, Object?>;
      expect((decoded['suggestions'] as List), hasLength(1));
    });

    test('no handles, no suggestions — still valid JSON', () async {
      final result = await FakeLlmProvider()
          .start(propose('Open (0): none\n'))
          .done;
      final decoded = jsonDecode(result.text) as Map<String, Object?>;
      expect(decoded['suggestions'], isEmpty);
    });

    test('a custom script still wins over the canned reply', () async {
      final fake = FakeLlmProvider(script: (_) => 'not json');
      final result = await fake.start(propose('- [t1] x\n')).done;
      expect(result.text, 'not json');
    });
  });

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

    test('a script that throws fails the call instead of hanging it', () async {
      final fake = FakeLlmProvider(script: (_) => throw StateError('no reply'));
      final result = await fake.start(ask('x')).done;
      expect(result.finish, LlmFinish.failed);
      expect(result.failure?.kind, LlmFailureKind.internal);
      expect(result.failure?.message, 'provider threw: StateError');
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
