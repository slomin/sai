/// The structured suggestion schema (#35), versioned in core: what a
/// proposal call constrains the model's answer to, via the request's
/// `response_format`. Kept deliberately inside the subset llama.cpp
/// converts to a grammar — `type`, `enum`, `properties`, `required`,
/// `additionalProperties: false`, `items`, `minItems`/`maxItems`, and
/// anchored `pattern` — so one schema serves every local backend;
/// `schema_test.dart` pins the subset.
library;

import '../llm/call.dart';

/// The payload version written on every `proposal.made` line.
const proposalSchemaVersion = 0;

/// The schema's wire name; a breaking change is a new name.
const proposalSchemaName = 'sai_proposal_v0';

/// Every property is required and unused ones travel empty (`""`, `[]`):
/// OpenAI-style strict mode admits no optional keys, and an optional
/// group in a pattern beats an empty alternative in the grammar.
const proposalSchema = <String, Object?>{
  'type': 'object',
  'additionalProperties': false,
  'required': ['suggestions', 'note'],
  'properties': {
    'suggestions': {
      'type': 'array',
      'maxItems': 8,
      'items': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['kind', 'task', 'when', 'deadline', 'parts', 'reason'],
        'properties': {
          'kind': {
            'type': 'string',
            'enum': ['schedule', 'deadline', 'split'],
          },
          'task': {'type': 'string', 'pattern': r'^t[0-9]+$'},
          'when': {
            'type': 'string',
            'pattern':
                r'^(today|tomorrow|someday|anytime'
                r'|[0-9]{4}-[0-9]{2}-[0-9]{2})?$',
          },
          'deadline': {
            'type': 'string',
            'pattern': r'^(today|tomorrow|none|[0-9]{4}-[0-9]{2}-[0-9]{2})?$',
          },
          'parts': {
            'type': 'array',
            'maxItems': 8,
            'items': {'type': 'string'},
          },
          'reason': {'type': 'string'},
        },
      },
    },
    'note': {'type': 'string'},
  },
};

/// The schema as a request carries it.
const proposalResponseSchema = ResponseSchema(
  name: proposalSchemaName,
  schema: proposalSchema,
);
