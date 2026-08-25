import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

import '../package_root.dart';

/// The spec's rule made mechanical for provider traffic: every type the
/// recorder writes has a registry row, and every `provider.*` row has a
/// constant.
void main() {
  late String spec;

  setUpAll(() async {
    final root = (await packageRoot()).parent.parent;
    spec = File('${root.path}/docs/archive/event-log-v0.md').readAsStringSync();
  });

  test('every provider event type has a registry row', () {
    expect(EventTypes.provider, hasLength(4));
    for (final type in EventTypes.provider) {
      expect(
        spec.contains('| `$type` |'),
        isTrue,
        reason: '$type is missing from docs/archive/event-log-v0.md',
      );
    }
  });

  test('every provider and policy registry row has a constant', () {
    final row = RegExp(
      r'^\| `((?:provider|policy)\.[a-z0-9_.]+)` \|',
      multiLine: true,
    );
    final documented = row.allMatches(spec).map((m) => m[1]!).toSet();
    expect(documented, {...EventTypes.provider, EventTypes.policyDecision});
  });
}
