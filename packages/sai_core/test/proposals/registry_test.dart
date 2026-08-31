import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

import '../package_root.dart';

/// The spec's own rule: producers add registry rows in the same change
/// that starts writing a new type. Mechanical for the proposal family,
/// as `test/tasks/registry_test.dart` is for the task domain.
void main() {
  late String spec;

  setUpAll(() async {
    final root = (await packageRoot()).parent.parent;
    spec = File('${root.path}/docs/archive/event-log-v0.md').readAsStringSync();
  });

  test('every proposal event type has a registry row', () {
    for (final type in ProposalEventTypes.all) {
      expect(
        spec.contains('| `$type` |'),
        isTrue,
        reason: '$type is missing from docs/archive/event-log-v0.md',
      );
    }
  });

  test('every proposal registry row has a constant', () {
    final row = RegExp(r'^\| `(proposal\.[a-z0-9_.]+)` \|', multiLine: true);
    final documented = row.allMatches(spec).map((m) => m[1]!).toSet();
    expect(documented, isNotEmpty);
    expect(documented, ProposalEventTypes.all.toSet());
  });
}
