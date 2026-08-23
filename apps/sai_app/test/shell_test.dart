import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/sai_app.dart';
import 'package:sai_core/sai_core.dart';
import 'package:yaml/yaml.dart';

void main() {
  testWidgets('shell shows the greeting from sai_core', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SaiApp()));
    expect(find.text('sai 2.0.0-dev — nothing here yet'), findsOneWidget);
  });

  testWidgets('shell reads through the shared provider layer', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appInfoProvider.overrideWithValue(
            const AppInfo(name: 'override', version: '0'),
          ),
        ],
        child: const SaiApp(),
      ),
    );
    expect(find.text('override 0 — nothing here yet'), findsOneWidget);
  });

  test('pubspec version matches saiVersion (build metadata aside)', () {
    // `flutter test` always runs with the project directory as CWD.
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    expect((pubspec['version'] as String).split('+').first, saiVersion);
  });
}
