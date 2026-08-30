import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  group('finished_task_visibility (#97)', () {
    test('is end-of-day until said otherwise, and is written only then', () {
      expect(
        Settings.empty.finishedTaskVisibility,
        FinishedTaskVisibility.endOfDay,
      );
      expect(
        Settings.decode('{"version":0}').finishedTaskVisibility,
        FinishedTaskVisibility.endOfDay,
      );
      final now = Settings.empty.withFinishedTaskVisibility(
        FinishedTaskVisibility.immediate,
      );
      expect(now.finishedTaskVisibility, FinishedTaskVisibility.immediate);
      expect(
        now.encode(),
        '{"finished_task_visibility":"immediate","llm":null,"version":0}',
      );
      expect(
        Settings.decode(now.encode()).finishedTaskVisibility,
        FinishedTaskVisibility.immediate,
      );
      expect(
        now
            .withFinishedTaskVisibility(FinishedTaskVisibility.endOfDay)
            .encode(),
        Settings.empty.encode(),
        reason: 'the default is not written',
      );
      expect(
        Settings.decode('{"version":0,"finished_task_visibility":"end_of_day"}')
            .encode(),
        Settings.empty.encode(),
        reason: 'an explicit default is read and not carried',
      );
    });

    test('every copy keeps it', () {
      final now = Settings.empty.withFinishedTaskVisibility(
        FinishedTaskVisibility.immediate,
      );
      const immediate = FinishedTaskVisibility.immediate;
      expect(now.withLlm('fake').finishedTaskVisibility, immediate);
      expect(now.withReasoning(true).finishedTaskVisibility, immediate);
      expect(
        now.withShareTasksWithCloud(true).finishedTaskVisibility,
        immediate,
      );
      expect(
        now
            .withProvider(ProviderConfig(id: 'a', kind: 'fake'))
            .finishedTaskVisibility,
        immediate,
      );
      expect(now.withoutProvider('a').finishedTaskVisibility, immediate);
      expect(
        now.withWorkspace(WorkspaceState.empty).finishedTaskVisibility,
        immediate,
      );
      expect(now.withSetupDone().finishedTaskVisibility, immediate);
    });

    test('a word this sai does not know reads as end-of-day and is not '
        'carried as an unknown key', () {
      final odd = Settings.decode(
        '{"version":0,"finished_task_visibility":"never"}',
      );
      expect(odd.finishedTaskVisibility, FinishedTaskVisibility.endOfDay);
      expect(odd.extra, isEmpty);
      expect(odd.encode(), Settings.empty.encode());
    });

    test('a value that is not a string is malformed', () {
      for (final bad in ['5', 'true', '{}', '["immediate"]']) {
        expect(
          () =>
              Settings.decode('{"version":0,"finished_task_visibility":$bad}'),
          throwsA(
            isA<SettingsFormatException>().having(
              (e) => e.reason,
              'reason',
              'finished_task_visibility must be end_of_day or immediate',
            ),
          ),
          reason: bad,
        );
      }
    });

    test('the notifier writes the file, and the provider follows', () {
      final tmp = Directory.systemTemp.createTempSync('sai_finished_test');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final file = File('${tmp.path}/settings.json');
      final container = ProviderContainer.test(
        overrides: [
          settingsFileProvider.overrideWithValue(file),
          builtinLlmsProvider.overrideWithValue([FakeLlmProvider.new]),
          defaultLlmIdProvider.overrideWithValue(null),
        ],
      );
      expect(
        container.read(finishedTaskVisibilityProvider),
        FinishedTaskVisibility.endOfDay,
      );
      container
          .read(settingsProvider.notifier)
          .setFinishedTaskVisibility(FinishedTaskVisibility.immediate);
      expect(
        container.read(finishedTaskVisibilityProvider),
        FinishedTaskVisibility.immediate,
      );
      expect(
        file.readAsStringSync(),
        '{"finished_task_visibility":"immediate","llm":null,"version":0}',
      );
      container
          .read(settingsProvider.notifier)
          .setFinishedTaskVisibility(FinishedTaskVisibility.endOfDay);
      expect(file.readAsStringSync(), '{"llm":null,"version":0}');
    });

    test('the wire names are the documented words', () {
      expect(FinishedTaskVisibility.endOfDay.wireName, 'end_of_day');
      expect(FinishedTaskVisibility.immediate.wireName, 'immediate');
      expect(
        FinishedTaskVisibility.fromWire('end_of_day'),
        FinishedTaskVisibility.endOfDay,
      );
      expect(
        FinishedTaskVisibility.fromWire('immediate'),
        FinishedTaskVisibility.immediate,
      );
      expect(FinishedTaskVisibility.fromWire('later'), isNull);
    });
  });
}
