import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  group('resolveSettingsFile', () {
    const support = '/Users/x/Library/Application Support/sai/settings.json';

    test('SAI_SETTINGS_FILE wins', () {
      final file = resolveSettingsFile(
        environment: {'SAI_SETTINGS_FILE': '/tmp/s.json', 'HOME': '/Users/x'},
        operatingSystem: 'macos',
      );
      expect(file.path, '/tmp/s.json');
    });

    test('otherwise the file sits in the data directory', () {
      expect(
        resolveSettingsFile(
          environment: {'HOME': '/Users/x'},
          operatingSystem: 'macos',
        ).path,
        support,
      );
      expect(
        resolveSettingsFile(
          environment: {'HOME': '/home/x', 'XDG_DATA_HOME': '/data'},
          operatingSystem: 'linux',
        ).path,
        '/data/sai/settings.json',
      );
    });

    test('SAI_ARCHIVE_ROOT does not move the settings', () {
      final file = resolveSettingsFile(
        environment: {'SAI_ARCHIVE_ROOT': '/tmp/sai-demo', 'HOME': '/Users/x'},
        operatingSystem: 'macos',
      );
      expect(file.path, support);
    });

    test('an empty override is no override', () {
      final file = resolveSettingsFile(
        environment: {'SAI_SETTINGS_FILE': '', 'HOME': '/Users/x'},
        operatingSystem: 'macos',
      );
      expect(file.path, support);
    });

    test('no HOME is an error that names the file', () {
      expect(
        () => resolveSettingsFile(
          environment: const {},
          operatingSystem: 'macos',
        ),
        throwsA(predicate((e) => e.toString().contains('SAI_SETTINGS_FILE'))),
      );
    });
  });
}
