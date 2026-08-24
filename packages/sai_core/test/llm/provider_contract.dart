import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

/// What every [LlmProvider] must do, whatever its transport. The fake
/// runs it here; the HTTP providers (#22) run it against a stub server.
/// [create] returns a fresh provider per test; [request] is one it can
/// answer with at least two deltas.
void llmProviderContract(
  String name,
  LlmProvider Function() create, {
  required LlmRequest Function() request,
}) {
  group('$name honours the LlmProvider contract:', () {
    late LlmProvider provider;

    setUp(() => provider = create());
    tearDown(() => provider.close());

    test('the deltas join to the result text', () async {
      final call = provider.start(request());
      final parts = <String>[];
      await for (final delta in call.deltas) {
        parts.add(delta.text);
      }
      final result = await call.done;
      expect(parts.length, greaterThanOrEqualTo(2));
      expect(parts.join(), result.text);
      expect(result.finish, LlmFinish.stop);
      expect(result.failure, isNull);
    });

    test('the result carries the provider and model lineage', () async {
      final result = await provider.start(request()).done;
      expect(result.model.provider, provider.id);
      expect(result.model.id, request().model ?? provider.defaultModel);
    });

    test('a requested model overrides the default', () async {
      final base = request();
      final result = await provider
          .start(
            LlmRequest(
              messages: base.messages,
              model: 'other-model',
              maxTokens: base.maxTokens,
              temperature: base.temperature,
            ),
          )
          .done;
      expect(result.model.id, 'other-model');
    });

    test('done completes once, and again with the same value', () async {
      final call = provider.start(request());
      final first = await call.done;
      final second = await call.done;
      expect(identical(first, second), isTrue);
    });

    test('cancel after the first delta is prompt and total', () async {
      final call = provider.start(request());
      final seen = <String>[];
      await for (final delta in call.deltas) {
        seen.add(delta.text);
        call.cancel();
      }
      final result = await call.done;
      expect(result.finish, LlmFinish.cancelled);
      expect(seen, hasLength(1));
      expect(result.text, seen.single);
    });

    test('cancel before any delta yields an empty cancelled result', () async {
      final call = provider.start(request());
      call.cancel();
      final result = await call.done;
      expect(result.finish, LlmFinish.cancelled);
      expect(result.text, isEmpty);
      expect(await call.deltas.toList(), isEmpty);
    });

    test('calls are independent', () async {
      final a = provider.start(request());
      final b = provider.start(request());
      a.cancel();
      final resultB = await b.done;
      expect(resultB.finish, LlmFinish.stop);
      expect((await a.done).finish, LlmFinish.cancelled);
      expect(resultB.model.requestId, isNot((await a.done).model.requestId));
    });

    test('close cancels a running call', () async {
      final call = provider.start(request());
      await provider.close();
      expect((await call.done).finish, LlmFinish.cancelled);
    });
  });
}
