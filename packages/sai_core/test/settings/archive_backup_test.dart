import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  group('archive_backup (#15)', () {
    test('is unset until said otherwise, and is written only then', () {
      expect(Settings.empty.archiveBackup, isNull);
      expect(Settings.decode('{"version":0}').archiveBackup, isNull);
      final set = Settings.empty.withArchiveBackup('/Volumes/Backup/sai');
      expect(set.archiveBackup, '/Volumes/Backup/sai');
      expect(
        set.encode(),
        '{"archive_backup":"/Volumes/Backup/sai","llm":null,"version":0}',
      );
      expect(
        Settings.decode(set.encode()).archiveBackup,
        '/Volumes/Backup/sai',
      );
      expect(
        set.withArchiveBackup(null).encode(),
        Settings.empty.encode(),
        reason: 'unset is not written',
      );
    });

    test('every copy keeps it', () {
      final set = Settings.empty.withArchiveBackup('/b');
      expect(set.withLlm('fake').archiveBackup, '/b');
      expect(set.withLlmOrder(['fake']).archiveBackup, '/b');
      expect(set.withReasoning(true).archiveBackup, '/b');
      expect(set.withShareTasksWithCloud(true).archiveBackup, '/b');
      expect(
        set.withProvider(ProviderConfig(id: 'a', kind: 'fake')).archiveBackup,
        '/b',
      );
      expect(set.withoutProvider('a').archiveBackup, '/b');
      expect(set.withWorkspace(WorkspaceState.empty).archiveBackup, '/b');
      expect(set.withSetupDone().archiveBackup, '/b');
      expect(
        set
            .withFinishedTaskVisibility(FinishedTaskVisibility.immediate)
            .archiveBackup,
        '/b',
      );
    });

    test('a wrong type makes the file unreadable', () {
      expect(
        () => Settings.decode('{"version":0,"archive_backup":5}'),
        throwsA(isA<SettingsFormatException>()),
      );
      expect(
        () => Settings.decode('{"version":0,"archive_backup":""}'),
        throwsA(isA<SettingsFormatException>()),
      );
    });

    test('a relative path reads as unset and is not carried', () {
      final odd = Settings.decode('{"version":0,"archive_backup":"backup"}');
      expect(odd.archiveBackup, isNull);
      expect(odd.extra, isEmpty);
      expect(odd.encode(), Settings.empty.encode());
    });

    test('the destination is checked against the archive root', () {
      const root = '/Users/me/Library/Application Support/sai/archive';
      String? check(String path) =>
          Settings.checkArchiveBackup(path, archiveRoot: root);
      expect(check('/Volumes/Backup/sai'), isNull);
      expect(check('/Users/me/Library/Application Support/sai-backup'), isNull);
      expect(check('backup'), contains('absolute'));
      expect(check(''), contains('absolute'));
      expect(check(root), contains('the archive itself'));
      expect(check('$root/'), contains('the archive itself'));
      expect(check('$root/replica'), contains('inside the archive'));
      expect(
        check('/Users/me/Library/Application Support/sai'),
        contains('contains the archive'),
      );
      expect(
        check('/Users/me/Library/Application Support/sai/archive/../replica'),
        isNull,
      );
    });

    test('setArchiveBackup writes the file', () {
      final tmp = Directory.systemTemp.createTempSync('sai_backup_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final file = File('${tmp.path}/settings.json');
      final container = ProviderContainer.test(
        overrides: [
          settingsFileProvider.overrideWithValue(file),
          builtinLlmsProvider.overrideWithValue([FakeLlmProvider.new]),
          defaultLlmIdProvider.overrideWithValue(null),
        ],
      );
      expect(container.read(settingsProvider).archiveBackup, isNull);
      container.read(settingsProvider.notifier).setArchiveBackup('/b');
      expect(container.read(settingsProvider).archiveBackup, '/b');
      expect(
        file.readAsStringSync(),
        '{"archive_backup":"/b","llm":null,"version":0}',
      );
      container.read(settingsProvider.notifier).setArchiveBackup(null);
      expect(file.readAsStringSync(), '{"llm":null,"version":0}');
    });
  });
}
