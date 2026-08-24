import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sai_core/sai_core.dart';
import 'package:yaml/yaml.dart';

import 'harness.dart';

void main() {
  testWidgets('the shell reads through the shared provider layer', (
    tester,
  ) async {
    await pumpApp(
      tester,
      overrides: [
        appInfoProvider.overrideWithValue(
          const AppInfo(name: 'override', version: '0'),
        ),
      ],
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
