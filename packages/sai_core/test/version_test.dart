import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'package_root.dart';

void main() {
  test('saiVersion matches the pubspec version', () async {
    final root = await packageRoot();
    final pubspec = loadYaml(
      File('${root.path}/pubspec.yaml').readAsStringSync(),
    ) as YamlMap;
    expect(pubspec['version'], saiVersion);
  });
}
