import '../call.dart';

/// The Responses API's role for a sai message: `system` goes as
/// `developer`, the word OpenAI's reasoning models read instructions
/// under (the API upgrades `system` to it on those models anyway, and the
/// App Server route says the same), so both OpenAI routes carry one role
/// mapping; `user` and `assistant` are themselves.
String responsesRole(LlmRole role) => switch (role) {
  LlmRole.system => 'developer',
  LlmRole.user => 'user',
  LlmRole.assistant => 'assistant',
};

/// The `POST /v1/responses` body for [request] on [model] (#26): every
/// message as one `input` item in sai's order — never concatenated into
/// `instructions`, never dropped — streamed, stored nowhere
/// (`store: false` is a request-storage choice, not a retention promise),
/// in the foreground, with no tools and no tool choice, no conversation
/// or `previous_response_id`, no metadata. `maxTokens` is
/// `max_output_tokens`; a temperature goes only when the caller set one;
/// an explicit effort — `none` included — is `reasoning.effort` exactly,
/// and Model default sends no `reasoning` at all; a schema is the strict
/// `text.format`. Pure: the same request gives the same body.
Map<String, Object?> responsesBody(
  LlmRequest request, {
  required String model,
}) => {
  'model': model,
  'input': [
    for (final m in request.messages)
      {'role': responsesRole(m.role), 'content': m.text},
  ],
  'stream': true,
  'store': false,
  'background': false,
  'tools': const <Object>[],
  'tool_choice': 'none',
  if (request.maxTokens != null) 'max_output_tokens': request.maxTokens,
  if (request.temperature != null) 'temperature': request.temperature,
  if (request.reasoningEffort case final effort?)
    'reasoning': {'effort': effort.word},
  if (request.responseSchema case final schema?)
    'text': {
      'format': {
        'type': 'json_schema',
        'name': schema.name,
        'strict': true,
        'schema': schema.schema,
      },
    },
};
