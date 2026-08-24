import 'dart:io';

import 'package:flutter/material.dart';
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

  testWidgets('the appearance follows the system', (tester) async {
    await pumpApp(tester);
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system);
    expect(app.theme, isNotNull);
    expect(app.darkTheme, isNotNull);
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.light,
    );
  });

  testWidgets('a dark system appearance renders the shell dark', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await pumpApp(tester);
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.dark,
    );
  });

  test('pubspec version matches saiVersion (build metadata aside)', () {
    // `flutter test` always runs with the project directory as CWD.
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    expect((pubspec['version'] as String).split('+').first, saiVersion);
  });
}
