import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  group('setup (#40)', () {
    test('is not done until said so, and is written only then', () {
      expect(Settings.empty.setupDone, isFalse);
      expect(Settings.decode('{"version":0}').setupDone, isFalse);
      final done = Settings.empty.withSetupDone();
      expect(done.setupDone, isTrue);
      expect(done.encode(), '{"llm":null,"setup":"done","version":0}');
      expect(Settings.decode(done.encode()).setupDone, isTrue);
    });

    test('every copy keeps it', () {
      final done = Settings.empty.withSetupDone();
      expect(done.withLlm('fake').setupDone, isTrue);
      expect(done.withReasoning(true).setupDone, isTrue);
      expect(done.withShareTasksWithCloud(true).setupDone, isTrue);
      expect(
        done.withProvider(ProviderConfig(id: 'a', kind: 'fake')).setupDone,
        isTrue,
      );
      expect(done.withoutProvider('a').setupDone, isTrue);
      expect(done.withWorkspace(WorkspaceState.empty).setupDone, isTrue);
    });

    test('a value this sai does not know reads as not done, and is not '
        'carried as an unknown key', () {
      final odd = Settings.decode('{"version":0,"setup":"later"}');
      expect(odd.setupDone, isFalse);
      expect(odd.extra, isEmpty);
      expect(Settings.decode('{"version":0,"setup":5}').setupDone, isFalse);
    });

    test('markSetupDone writes the file once', () {
      final tmp = Directory.systemTemp.createTempSync('sai_setup_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final file = File('${tmp.path}/settings.json');
      final container = ProviderContainer.test(
        overrides: [
          settingsFileProvider.overrideWithValue(file),
          builtinLlmsProvider.overrideWithValue([FakeLlmProvider.new]),
          defaultLlmIdProvider.overrideWithValue(null),
        ],
      );
      expect(container.read(settingsProvider).setupDone, isFalse);
      expect(file.existsSync(), isFalse);
      container.read(settingsProvider.notifier).markSetupDone();
      expect(container.read(settingsProvider).setupDone, isTrue);
      expect(
        file.readAsStringSync(),
        '{"llm":null,"setup":"done","version":0}',
      );
      final stamp = file.lastModifiedSync();
      container.read(settingsProvider.notifier).markSetupDone();
      expect(file.lastModifiedSync(), stamp, reason: 'already done');
    });
  });
}
