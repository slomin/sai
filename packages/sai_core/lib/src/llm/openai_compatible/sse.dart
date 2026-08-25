import 'dart:async';
import 'dart:convert';

/// One server-sent event's `data`, the lines joined with `\n`.
final class SseEvent {
  const SseEvent(this.data);

  final String data;

  /// The OpenAI end-of-stream sentinel.
  bool get isDone => data == '[DONE]';
}

/// Frames a byte stream into [SseEvent]s: `data:` lines accumulate, a
/// blank line ends an event, comment (`:`) and other field lines are
/// ignored, and both `\n` and `\r\n` are line ends. An event still open
/// when the stream closes is delivered — a server that sends `[DONE]`
/// without a trailing blank line still ends cleanly.
StreamTransformer<T, SseEvent> sseEvents<T extends List<int>>() =>
    StreamTransformer.fromBind((bytes) {
      final lines = utf8.decoder.bind(bytes).transform(const LineSplitter());
      return _frame(lines);
    });

Stream<SseEvent> _frame(Stream<String> lines) async* {
  List<String>? data;
  await for (final line in lines) {
    if (line.isEmpty) {
      if (data != null) yield SseEvent(data.join('\n'));
      data = null;
      continue;
    }
    if (line.startsWith(':')) continue;
    if (!line.startsWith('data:')) continue;
    var value = line.substring(5);
    if (value.startsWith(' ')) value = value.substring(1);
    (data ??= []).add(value);
  }
  if (data != null) yield SseEvent(data.join('\n'));
}
