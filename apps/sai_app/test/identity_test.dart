import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_core/sai_core.dart';
import 'package:sai_app/top_bar.dart';

import 'harness.dart';

/// The two installed flavors (#90, ADR 0019) look different on purpose:
/// dev says so in the header and the title, stable stays as it was.
void main() {
  testWidgets('the dev flavor wears a DEV label and names itself', (
    tester,
  ) async {
    await pumpApp(tester, identity: SaiIdentity.dev);
    expect(find.byKey(devLabelKey), findsOneWidget);
    expect(find.text('DEV'), findsOneWidget);
    expect(find.text('sai'), findsWidgets);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, 'sai dev');
  });

  testWidgets('the stable flavor shows no label at all', (tester) async {
    await pumpApp(tester);
    expect(find.byKey(devLabelKey), findsNothing);
    expect(find.text('DEV'), findsNothing);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, 'sai');
  });

  test('an unflavored build is dev — nothing accidental looks stable', () {
    expect(SaiIdentity.fromFlavor(null), SaiIdentity.dev);
  });
}
