import '../archive/event.dart';
import 'call.dart';
import 'failure.dart';
import 'provider.dart';

/// A provider that answers deterministically and offline: the reply comes
/// from [script] (by default the last user message, echoed), streamed
/// word by word. Usage is word counts, the request id a counter.
///
/// Between deltas the fake yields one event-loop turn (`delta` zero) or
/// sleeps [delta], so tests can cancel after exactly N deltas and the
/// offline demo can look like a stream. [failWith] fails the call after
/// [failAfter] deltas.
final class FakeLlmProvider implements LlmProvider {
  FakeLlmProvider({
    this.id = 'fake',
    this.displayName = 'fake',
    this.privacy = LlmPrivacy.local,
    this.defaultModel = 'fake-1',
    String Function(LlmRequest request)? script,
    this.failWith,
    this.failAfter = 0,
    this.delta = Duration.zero,
  }) : script = script ?? _echo;

  @override
  final String id;

  @override
  final String displayName;

  @override
  final LlmPrivacy privacy;

  @override
  final String defaultModel;

  /// The reply for a request, before chunking.
  final String Function(LlmRequest request) script;

  /// When set, every call fails with this after [failAfter] deltas.
  final LlmFailure? failWith;
  final int failAfter;

  /// The pause between deltas.
  final Duration delta;

  final _running = <LlmCallController>{};
  var _requests = 0;

  /// Requests started so far.
  int get requests => _requests;

  @override
  LlmCall start(LlmRequest request) {
    final model = ModelRef(
      provider: id,
      id: request.model ?? defaultModel,
      version: 'fake-1',
      requestId: 'fake-req-${++_requests}',
    );
    final controller = LlmCallController(model: model);
    _running.add(controller);
    controller.call.done.whenComplete(() => _running.remove(controller));
    controller.run(() => _run(controller, request));
    return controller.call;
  }

  Future<void> _run(LlmCallController controller, LlmRequest request) async {
    final words = _chunks(script(request));
    final promptWords = request.messages
        .map((m) => _chunks(m.text).length)
        .fold(0, (a, b) => a + b);
    final limit = request.maxTokens;
    final cut = limit != null && limit < words.length;
    final reply = cut ? words.sublist(0, limit) : words;
    var emitted = 0;
    for (final word in reply) {
      if (failWith != null && emitted == failAfter) break;
      // Never a delta before start() has returned: the pause comes first.
      await Future<void>.delayed(delta);
      if (controller.isDone) return;
      controller.add(word);
      emitted++;
      controller.usage = _usage(promptWords, emitted);
    }
    await Future<void>.delayed(delta);
    if (controller.isDone) return;
    final usage = _usage(promptWords, emitted);
    final failure = failWith;
    if (failure != null) {
      controller.finish(
        LlmResult(
          text: controller.text,
          finish: LlmFinish.failed,
          model: controller.model,
          usage: usage,
          failure: failure,
        ),
      );
      return;
    }
    controller.finish(
      LlmResult(
        text: controller.text,
        finish: cut ? LlmFinish.length : LlmFinish.stop,
        model: controller.model,
        usage: usage,
      ),
    );
  }

  @override
  Future<void> close() async {
    for (final controller in _running.toList()) {
      controller.cancel();
    }
  }

  static LlmUsage _usage(int prompt, int completion) => LlmUsage(
    promptTokens: prompt,
    completionTokens: completion,
    totalTokens: prompt + completion,
  );

  static String _echo(LlmRequest request) => request.messages
      .lastWhere(
        (m) => m.role == LlmRole.user,
        orElse: () => request.messages.last,
      )
      .text;

  /// Words with their trailing whitespace, so the chunks join back to
  /// the exact reply.
  static List<String> _chunks(String text) =>
      _word.allMatches(text).map((m) => m[0]!).toList();

  static final _word = RegExp(r'\S+\s*');
}
