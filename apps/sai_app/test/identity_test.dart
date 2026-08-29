import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_core/sai_core.dart';
import 'package:sai_app/platform/flavor.dart';
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

  group('resolveIdentity', () {
    final messenger =
        TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
    void runnerSays(String? flavor) {
      messenger.setMockMethodCallHandler(flavorChannel, (call) async {
        if (call.method == 'flavor') return flavor;
        throw MissingPluginException();
      });
    }

    tearDown(() => messenger.setMockMethodCallHandler(flavorChannel, null));

    test('the bundle decides, whatever the Dart define says', () async {
      runnerSays('stable');
      expect(await resolveIdentity(dartFlavor: null), SaiIdentity.stable);
      expect(await resolveIdentity(dartFlavor: 'stable'), SaiIdentity.stable);
      runnerSays('dev');
      expect(await resolveIdentity(dartFlavor: null), SaiIdentity.dev);
      expect(await resolveIdentity(dartFlavor: 'dev'), SaiIdentity.dev);
    });

    test(
      'a bundle and a Dart build of different flavors is an error',
      () async {
        runnerSays('dev');
        expect(resolveIdentity(dartFlavor: 'stable'), throwsStateError);
        runnerSays('stable');
        expect(resolveIdentity(dartFlavor: 'dev'), throwsStateError);
      },
    );

    test('a bundle with no flavor or a third one is never stable', () async {
      runnerSays(null);
      expect(await resolveIdentity(dartFlavor: null), SaiIdentity.dev);
      runnerSays('qa');
      expect(resolveIdentity(dartFlavor: null), throwsStateError);
    });

    test('without a Runner the Dart define decides', () async {
      messenger.setMockMethodCallHandler(flavorChannel, null);
      expect(await resolveIdentity(dartFlavor: 'stable'), SaiIdentity.stable);
      expect(await resolveIdentity(dartFlavor: null), SaiIdentity.dev);
    });
  });
}
