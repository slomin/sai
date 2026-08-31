import 'dart:convert';

import '../call.dart';

/// What one `chat.completion.chunk` says. Everything is optional: a
/// chunk may carry a delta, a finish reason, usage (with
/// `stream_options.include_usage`), llama.cpp `timings`, or nothing.
final class ChatChunk {
  const ChatChunk({
    this.id,
    this.model,
    this.content,
    this.reasoning,
    this.finishReason,
    this.usage,
    this.tokensPerSecond,
    this.error = false,
  });

  final String? id;
  final String? model;

  /// `choices[0].delta.content` — the answer.
  final String? content;

  /// `choices[0].delta.reasoning_content` (LM Studio, DeepSeek) or
  /// `delta.reasoning` (OpenRouter and others): the model thinking
  /// aloud, kept apart from the answer.
  final String? reasoning;

  /// `choices[0].finish_reason`, e.g. `stop`, `length`.
  final String? finishReason;

  /// Token counts, where the chunk carries `usage`.
  final LlmUsage? usage;

  /// llama.cpp's `timings.predicted_per_second`.
  final double? tokensPerSecond;

  /// The chunk carries an `error` — an OpenAI-style refusal sent inside
  /// the stream. Its text is not kept.
  final bool error;

  /// Parses one event's data. Throws [FormatException] when it is not a
  /// JSON object — the caller turns that into a protocol failure with a
  /// fixed message; the text of this exception is never recorded.
  static ChatChunk parse(String data) {
    final Object? json;
    try {
      json = jsonDecode(data);
    } on FormatException {
      throw const FormatException('not JSON');
    }
    if (json is! Map<String, Object?>) {
      throw const FormatException('not an object');
    }
    final choices = json['choices'];
    Map<String, Object?>? first;
    if (choices is List && choices.isNotEmpty) {
      final c = choices.first;
      if (c is Map<String, Object?>) first = c;
    }
    String? content;
    String? reasoning;
    String? finish;
    if (first != null) {
      final delta = first['delta'];
      if (delta is Map<String, Object?>) {
        if (delta['content'] is String) content = delta['content'] as String;
        final thought = delta['reasoning_content'] ?? delta['reasoning'];
        if (thought is String) reasoning = thought;
      }
      if (first['finish_reason'] is String) {
        finish = first['finish_reason'] as String;
      }
    }
    LlmUsage? usage;
    final u = json['usage'];
    if (u is Map<String, Object?>) {
      usage = LlmUsage(
        promptTokens: _int(u['prompt_tokens']),
        completionTokens: _int(u['completion_tokens']),
        totalTokens: _int(u['total_tokens']),
        cost: u['cost'] is num ? (u['cost'] as num).toDouble() : null,
      );
    }
    double? tps;
    final timings = json['timings'];
    if (timings is Map<String, Object?>) {
      final v = timings['predicted_per_second'];
      if (v is num) tps = v.toDouble();
    }
    return ChatChunk(
      id: json['id'] is String ? json['id'] as String : null,
      model: json['model'] is String ? json['model'] as String : null,
      content: content,
      reasoning: reasoning,
      finishReason: finish,
      usage: usage,
      tokensPerSecond: tps,
      error: json['error'] != null,
    );
  }

  static int? _int(Object? v) => v is num ? v.toInt() : null;
}
