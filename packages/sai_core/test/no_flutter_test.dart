import 'dart:io';

import 'package:test/test.dart';

/// `sai_core` is pure Dart. Any Flutter import here would drag the whole
/// Flutter SDK into the terminal client and break `dart test`.
void main() {
  test('lib/ does not import Flutter', () {
    final offenders = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => f.readAsStringSync().contains('package:flutter'))
        .map((f) => f.path)
        .toList();
    expect(offenders, isEmpty);
  });

  test('pubspec.yaml does not depend on Flutter', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec.contains('flutter'), isFalse);
  });
}
