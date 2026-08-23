import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'package_root.dart';

/// `sai_core` is pure Dart. Any Flutter import here would drag the whole
/// Flutter SDK into the terminal client and break `dart test`.
void main() {
  late Directory root;

  setUpAll(() async => root = await packageRoot());

  test('lib/ does not import Flutter or dart:ui', () {
    final offenders = Directory('${root.path}/lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) {
          final src = f.readAsStringSync();
          return src.contains('package:flutter') || src.contains('dart:ui');
        })
        .map((f) => f.path)
        .toList();
    expect(offenders, isEmpty);
  });

  test('pubspec.yaml declares no Flutter dependency', () {
    final pubspec = loadYaml(
      File('${root.path}/pubspec.yaml').readAsStringSync(),
    ) as YamlMap;
    for (final section in ['dependencies', 'dev_dependencies']) {
      final deps = pubspec[section] as YamlMap? ?? YamlMap();
      for (final entry in deps.entries) {
        expect(
          entry.key,
          isNot(startsWith('flutter')),
          reason: '$section declares ${entry.key}',
        );
        final spec = entry.value;
        expect(
          spec is YamlMap && spec['sdk'] == 'flutter',
          isFalse,
          reason: '$section: ${entry.key} comes from the Flutter SDK',
        );
      }
    }
  });
}
