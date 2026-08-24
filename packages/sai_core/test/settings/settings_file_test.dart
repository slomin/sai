import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  group('resolveSettingsFile', () {
    test('SAI_SETTINGS_FILE wins', () {
      final file = resolveSettingsFile(
        environment: {'SAI_SETTINGS_FILE': '/tmp/s.json'},
        archiveRoot: Directory('/data/sai/archive'),
      );
      expect(file.path, '/tmp/s.json');
    });

    test('otherwise the file sits beside the archive directory', () {
      final file = resolveSettingsFile(
        environment: const {},
        archiveRoot: Directory(
          '/Users/x/Library/Application Support/sai/archive',
        ),
      );
      expect(
        file.path,
        '/Users/x/Library/Application Support/sai/settings.json',
      );
    });

    test('an empty override is no override', () {
      final file = resolveSettingsFile(
        environment: {'SAI_SETTINGS_FILE': ''},
        archiveRoot: Directory('/data/sai/archive'),
      );
      expect(file.path, '/data/sai/settings.json');
    });
  });
}
