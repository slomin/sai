import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  test('stays inside the llama.cpp grammar subset', () {
    // What llama-server's schema→GBNF conversion supports without
    // silently skipping; unsupported keywords would weaken the grammar
    // with no error. Patterns must be anchored.
    const allowed = {
      'type',
      'enum',
      'properties',
      'required',
      'additionalProperties',
      'items',
      'minItems',
      'maxItems',
      'pattern',
    };
    void check(Map<String, Object?> schema) {
      for (final key in schema.keys) {
        expect(allowed, contains(key), reason: "schema key '$key'");
      }
      if (schema['pattern'] case final String pattern) {
        expect(
          pattern.startsWith('^') && pattern.endsWith(r'$'),
          isTrue,
          reason: 'unanchored pattern: $pattern',
        );
      }
      if (schema['type'] == 'object') {
        expect(schema['additionalProperties'], isFalse);
        final properties = (schema['properties'] as Map)
            .cast<String, Object?>();
        expect(
          (schema['required'] as List).toSet(),
          properties.keys.toSet(),
          reason: 'strict mode admits no optional property',
        );
        for (final value in properties.values) {
          check((value as Map).cast<String, Object?>());
        }
      }
      if (schema['items'] case final Map items) {
        check(items.cast<String, Object?>());
      }
    }

    check(Map<String, Object?>.from(proposalSchema));
  });

  test('name, version and wire shape are pinned', () {
    expect(proposalSchemaName, 'sai_proposal_v0');
    expect(proposalSchemaVersion, 0);
    expect(proposalResponseSchema.name, proposalSchemaName);
    expect(proposalResponseSchema.schema, same(proposalSchema));
    final wire = proposalResponseSchema.toWire();
    expect(wire['type'], 'json_schema');
    expect((wire['json_schema'] as Map)['strict'], isTrue);
  });
}
