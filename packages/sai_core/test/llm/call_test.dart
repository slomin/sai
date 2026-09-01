import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

const model = ModelRef(provider: 'test', id: 'm');

LlmResult stop(String text) =>
    LlmResult(text: text, finish: LlmFinish.stop, model: model);

void main() {
  group('LlmCallController', () {
    test('delivers deltas and then exactly one result', () async {
      final controller = LlmCallController(model: model);
      final seen = <String>[];
      final sub = controller.call.deltas.listen((d) => seen.add(d.text));
      controller.add('hel');
      controller.add('lo');
      controller.finish(stop('hello'));
      final result = await controller.call.done;
      await sub.asFuture<void>();
      expect(seen, ['hel', 'lo']);
      expect(result.text, 'hello');
      expect(result.finish, LlmFinish.stop);
      expect(controller.isDone, isTrue);
    });

    test('the first finish wins and later deltas are ignored', () async {
      final controller = LlmCallController(model: model);
      final seen = <String>[];
      controller.call.deltas.listen((d) => seen.add(d.text));
      controller.add('first');
      controller.finish(stop('first'));
      controller.finish(stop('second'));
      controller.add('late');
      expect((await controller.call.done).text, 'first');
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['first']);
    });

    test(
      'cancel finishes now with the text so far and runs onCancel once',
      () async {
        var cancels = 0;
        final controller = LlmCallController(
          model: model,
          onCancel: () => cancels++,
        );
        controller.add('par');
        controller.add('tial');
        controller.usage = const LlmUsage(completionTokens: 2);
        controller.cancel();
        controller.cancel();
        final result = await controller.call.done;
        expect(result.finish, LlmFinish.cancelled);
        expect(result.text, 'partial');
        expect(result.usage?.completionTokens, 2);
        expect(result.failure, isNull);
        expect(controller.isCancelled, isTrue);
        expect(cancels, 1);
        // A provider that finishes after the cancel changes nothing.
        controller.finish(stop('too late'));
        expect((await controller.call.done).text, 'partial');
      },
    );

    test('cancel after done is a no-op', () async {
      var cancels = 0;
      final controller = LlmCallController(
        model: model,
        onCancel: () => cancels++,
      );
      controller.add('done');
      controller.finish(stop('done'));
      controller.cancel();
      expect(controller.isCancelled, isFalse);
      expect(cancels, 0);
      expect((await controller.call.done).finish, LlmFinish.stop);
    });

    test('the deltas stream closes once and never errors', () async {
      final controller = LlmCallController(model: model);
      final events = <Object>[];
      var closes = 0;
      controller.call.deltas.listen(
        events.add,
        onError: events.add,
        onDone: () => closes++,
      );
      controller.add('a');
      controller.finish(
        LlmResult(
          text: 'a',
          finish: LlmFinish.failed,
          model: model,
          failure: const LlmFailure(LlmFailureKind.timeout, 'no answer'),
        ),
      );
      await controller.call.done;
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(closes, 1);
    });

    test('a result whose text differs from the deltas is rejected', () {
      final controller = LlmCallController(model: model);
      controller.add('a');
      expect(() => controller.finish(stop('b')), throwsArgumentError);
    });
  });

  group('LlmCallController.run', () {
    test('a body that throws fails the call with the text so far', () async {
      final controller = LlmCallController(model: model);
      controller.run(() async {
        controller.add('par');
        throw StateError('adapter bug');
      });
      final result = await controller.call.done;
      expect(result.finish, LlmFinish.failed);
      expect(result.text, 'par');
      expect(result.failure?.kind, LlmFailureKind.internal);
      expect(result.failure?.message, 'provider threw: StateError');
    });

    test('a body that finishes with the wrong text fails, not hangs', () async {
      final controller = LlmCallController(model: model);
      controller.run(() async {
        controller.add('a');
        controller.finish(stop('b'));
      });
      final result = await controller.call.done;
      expect(result.finish, LlmFinish.failed);
      expect(result.failure?.kind, LlmFailureKind.internal);
      expect(result.text, 'a');
    });

    test('a body that returns without finishing fails the call', () async {
      final controller = LlmCallController(model: model);
      controller.run(() async {});
      final result = await controller.call.done;
      expect(result.finish, LlmFinish.failed);
      expect(result.failure?.message, contains('without finishing'));
    });

    test('a body that finishes normally is left alone', () async {
      final controller = LlmCallController(model: model);
      controller.run(() async {
        controller.add('ok');
        controller.finish(stop('ok'));
      });
      expect((await controller.call.done).finish, LlmFinish.stop);
    });
  });

  group('LlmRequest', () {
    test('needs at least one message', () {
      expect(() => LlmRequest(messages: const []), throwsArgumentError);
    });

    test(
      'rejects an empty model, a non-positive max_tokens, a bad temperature',
      () {
        final messages = [const LlmMessage(LlmRole.user, 'hi')];
        expect(
          () => LlmRequest(messages: messages, model: ''),
          throwsArgumentError,
        );
        expect(
          () => LlmRequest(messages: messages, maxTokens: 0),
          throwsArgumentError,
        );
        expect(
          () => LlmRequest(messages: messages, maxTokens: -1),
          throwsArgumentError,
        );
        expect(
          () => LlmRequest(messages: messages, temperature: -0.1),
          throwsArgumentError,
        );
        expect(
          () => LlmRequest(messages: messages, temperature: double.nan),
          throwsArgumentError,
        );
        expect(
          LlmRequest(
            messages: messages,
            maxTokens: 1,
            temperature: 0,
          ).maxTokens,
          1,
        );
      },
    );
  });

  group('LlmRequest.reasoningEffort (#26)', () {
    LlmRequest ask(ReasoningEffort? effort) => LlmRequest(
      messages: const [LlmMessage(LlmRole.user, 'hi')],
      taskContext: 'tasks',
      reasoningEffort: effort,
    );

    test('survives every request copy, word for word', () {
      for (final effort in [
        ReasoningEffort.none,
        const ReasoningEffort('xhigh'),
        const ReasoningEffort('a-word-from-the-future'),
      ]) {
        final request = ask(effort);
        expect(request.assembled().reasoningEffort, effort);
        expect(
          request
              .forCloud(sendTaskContext: true, keepCompactHistory: true)
              .reasoningEffort,
          effort,
        );
        expect(
          request
              .forCloud(sendTaskContext: false, keepCompactHistory: false)
              .reasoningEffort,
          effort,
        );
      }
      expect(ask(null).assembled().reasoningEffort, isNull);
    });

    test('withoutReasoning leaves the effort to the backend', () {
      expect(
        ask(const ReasoningEffort('high')).withoutReasoning().reasoningEffort,
        isNull,
      );
    });
  });

  group('ResponseSchema (#35)', () {
    const schema = ResponseSchema(
      name: 'sai_proposal_v0',
      schema: {'type': 'object'},
    );

    test('goes on the wire in the OpenAI nesting', () {
      expect(schema.toWire(), {
        'type': 'json_schema',
        'json_schema': {
          'name': 'sai_proposal_v0',
          'strict': true,
          'schema': {'type': 'object'},
        },
      });
    });

    test('survives every request copy', () {
      final request = LlmRequest(
        messages: const [LlmMessage(LlmRole.user, 'q')],
        taskContext: 'Today (0): none',
        reasoningEffort: ReasoningEffort.none,
        responseSchema: schema,
      );
      expect(request.assembled().responseSchema, same(schema));
      expect(request.withoutReasoning().responseSchema, same(schema));
      expect(
        request
            .forCloud(sendTaskContext: true, keepCompactHistory: true)
            .responseSchema,
        same(schema),
      );
    });
  });

  group('LlmResult', () {
    test('a failure is present exactly when the finish is failed', () {
      const failure = LlmFailure(LlmFailureKind.timeout, 'x');
      expect(
        () => LlmResult(text: '', finish: LlmFinish.failed, model: model),
        throwsArgumentError,
      );
      expect(
        () => LlmResult(
          text: '',
          finish: LlmFinish.stop,
          model: model,
          failure: failure,
        ),
        throwsArgumentError,
      );
      expect(
        LlmResult(
          text: '',
          finish: LlmFinish.failed,
          model: model,
          failure: failure,
        ).failure,
        same(failure),
      );
    });

    test('messages are unmodifiable', () {
      final request = LlmRequest(
        messages: [const LlmMessage(LlmRole.user, 'hi')],
      );
      expect(
        () => request.messages.add(const LlmMessage(LlmRole.user, 'x')),
        throwsUnsupportedError,
      );
      expect(request.messages.single.toJson(), {'role': 'user', 'text': 'hi'});
    });
  });

  group('LlmUsage', () {
    test('toJson keeps only what was reported', () {
      expect(const LlmUsage().toJson(), isEmpty);
      expect(
        const LlmUsage(
          promptTokens: 1,
          completionTokens: 2,
          totalTokens: 3,
          tokensPerSecond: 4.5,
          cost: 0.0042,
        ).toJson(),
        {
          'prompt_tokens': 1,
          'completion_tokens': 2,
          'total_tokens': 3,
          'tokens_per_second': 4.5,
          'cost': 0.0042,
        },
      );
    });
  });

  group('LlmFailure', () {
    test('reads like a sentence and serialises without secrets', () {
      const failure = LlmFailure(
        LlmFailureKind.unreachable,
        'connection refused',
        endpoint: 'http://lan:8080',
      );
      expect(
        failure.toString(),
        'LlmFailure(unreachable): connection refused (http://lan:8080)',
      );
      expect(failure.toJson(), {
        'kind': 'unreachable',
        'message': 'connection refused',
        'endpoint': 'http://lan:8080',
      });
      const rejected = LlmFailure(LlmFailureKind.rejected, 'bad', status: 401);
      expect(rejected.toString(), 'LlmFailure(rejected): bad [401]');
      expect(rejected.toJson()['status'], 401);
    });
  });
}
