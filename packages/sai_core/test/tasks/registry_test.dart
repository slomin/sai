import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

import '../package_root.dart';

/// The spec's own rule: producers add registry rows in the same change that
/// starts writing a new type. This test makes that rule mechanical for the
/// task domain.
void main() {
  late String spec;

  setUpAll(() async {
    final root = (await packageRoot()).parent.parent;
    spec = File('${root.path}/docs/archive/event-log-v0.md').readAsStringSync();
  });

  test('every task event type has a registry row', () {
    for (final type in TaskEventTypes.all) {
      expect(
        spec.contains('| `$type` |'),
        isTrue,
        reason: '$type is missing from docs/archive/event-log-v0.md',
      );
    }
  });

  test('every task-domain registry row has a constant', () {
    final row = RegExp(
      r'^\| `((?:task|area|project|heading|tag)\.[a-z0-9_.]+)` \|',
      multiLine: true,
    );
    final documented = row.allMatches(spec).map((m) => m[1]!).toSet();
    expect(documented, isNotEmpty);
    expect(documented, TaskEventTypes.all.toSet());
  });
}
