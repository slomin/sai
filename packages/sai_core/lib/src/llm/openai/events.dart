import 'dart:convert';

import '../call.dart';

/// What one Responses API stream event means to sai. The stream is
/// read by the `type` inside each `data` object (the SSE `event:` line
/// says the same and is not relied on), never by position: text deltas,
/// reasoning-summary deltas, one of three terminal events, an error, an
/// output item sai did not ask for — and everything else, which is
/// passive and skipped.
enum ResponsesEventKind {
  /// `response.output_text.delta`: answer text.
  text,

  /// `response.reasoning_summary_text.delta`: the model's summarised
  /// thinking, shown only because upstream chose to send it.
  reasoning,

  /// `response.completed`: the answer is whole; model and usage are on
  /// the terminal response.
  completed,

  /// `response.incomplete`: the answer stopped short — at the output
  /// cap, or for a reason upstream names.
  incomplete,

  /// `response.failed`, or a bare `error` event: upstream failed the
  /// response. Nothing of its text is kept.
  failed,

  /// `response.output_item.added` with an item that is not a message or
  /// reasoning — a tool call sai never asked for. Fail closed.
  unexpectedItem,

  /// A `response.created`, `response.in_progress`, `…done` marker or any
  /// type sai does not know: nothing to do.
  other,
}

/// One parsed stream event.
final class ResponsesEvent {
  const ResponsesEvent(
    this.kind, {
    this.delta,
    this.model,
    this.usage,
    this.incompleteReason,
    this.responseId,
  });

  final ResponsesEventKind kind;

  /// The text piece of a [ResponsesEventKind.text] or
  /// [ResponsesEventKind.reasoning] event.
  final String? delta;

  /// The model that answered, from a terminal response.
  final String? model;

  /// Token usage, from a terminal response.
  final LlmUsage? usage;

  /// `incomplete_details.reason` of an incomplete response.
  final String? incompleteReason;

  /// The response's own id, from a terminal response — the lineage's
  /// request id.
  final String? responseId;

  /// Parses one event's `data`. Throws [FormatException] for anything
  /// that is not a JSON object with a string `type` — the stream is then
  /// a protocol failure, not a guess.
  static ResponsesEvent parse(String data) {
    final Object? json;
    try {
      json = jsonDecode(data);
    } on FormatException {
      throw const FormatException('event is not JSON');
    }
    if (json is! Map<String, Object?> || json['type'] is! String) {
      throw const FormatException('event has no type');
    }
    final type = json['type'] as String;
    switch (type) {
      case 'response.output_text.delta':
        return ResponsesEvent(
          ResponsesEventKind.text,
          delta: _string(json['delta']),
        );
      case 'response.reasoning_summary_text.delta':
        return ResponsesEvent(
          ResponsesEventKind.reasoning,
          delta: _string(json['delta']),
        );
      case 'response.completed':
        return _terminal(ResponsesEventKind.completed, json);
      case 'response.incomplete':
        return _terminal(ResponsesEventKind.incomplete, json);
      case 'response.failed':
      case 'error':
        return const ResponsesEvent(ResponsesEventKind.failed);
      case 'response.output_item.added':
        final item = json['item'];
        final itemType = item is Map<String, Object?> ? item['type'] : null;
        return ResponsesEvent(
          itemType == 'message' || itemType == 'reasoning'
              ? ResponsesEventKind.other
              : ResponsesEventKind.unexpectedItem,
        );
      default:
        return const ResponsesEvent(ResponsesEventKind.other);
    }
  }

  static String? _string(Object? value) => value is String ? value : null;

  static ResponsesEvent _terminal(
    ResponsesEventKind kind,
    Map<String, Object?> json,
  ) {
    final response = json['response'];
    if (response is! Map<String, Object?>) return ResponsesEvent(kind);
    final usage = response['usage'];
    final details = response['incomplete_details'];
    return ResponsesEvent(
      kind,
      model: _string(response['model']),
      responseId: _string(response['id']),
      usage: usage is Map<String, Object?>
          ? LlmUsage(
              promptTokens: _int(usage['input_tokens']),
              completionTokens: _int(usage['output_tokens']),
              totalTokens: _int(usage['total_tokens']),
            )
          : null,
      incompleteReason: details is Map<String, Object?>
          ? _string(details['reason'])
          : null,
    );
  }

  static int? _int(Object? value) => value is num ? value.toInt() : null;
}
