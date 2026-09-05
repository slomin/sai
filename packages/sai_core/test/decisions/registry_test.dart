import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

import '../package_root.dart';

/// The spec's own rule: producers add registry rows in the same change
/// that starts writing a new type. Mechanical for the decision family,
/// as `test/proposals/registry_test.dart` is for proposals.
void main() {
  late String spec;

  setUpAll(() async {
    final root = (await packageRoot()).parent.parent;
    spec = File('${root.path}/docs/archive/event-log-v0.md').readAsStringSync();
  });

  test('every decision event type has a registry row', () {
    for (final type in DecisionEventTypes.all) {
      expect(
        spec.contains('| `$type` |'),
        isTrue,
        reason: '$type is missing from docs/archive/event-log-v0.md',
      );
    }
  });

  test('every decision registry row has a constant', () {
    final row = RegExp(r'^\| `(decision\.[a-z0-9_.]+)` \|', multiLine: true);
    final documented = row.allMatches(spec).map((m) => m[1]!).toSet();
    expect(documented, isNotEmpty);
    expect(documented, DecisionEventTypes.all.toSet());
  });

  test('the bare name is no longer reserved', () {
    expect(spec, isNot(contains('reserved for #14')));
  });
}
