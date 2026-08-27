import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:sai_core/things_testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_import_state_test');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String seed({int tasks = 1}) {
    final path = p.join(tmp.path, 'main.sqlite');
    final f = ThingsFixture(path);
    final home = f.area('Home');
    final kitchen = f.project('Kitchen', area: home, start: 1);
    for (var i = 0; i < tasks; i++) {
      f.item('Buy oat milk $i', project: kitchen, start: 1);
    }
    f.item('Old', trashed: true);
    f.close();
    return path;
  }

  ProviderContainer make({
    Map<String, String> environment = const {},
    List<Override> overrides = const [],
  }) => ProviderContainer.test(
    overrides: [
      archiveRootProvider.overrideWithValue(
        Directory(p.join(tmp.path, 'archive')),
      ),
      settingsFileProvider.overrideWithValue(
        File(p.join(tmp.path, 'settings.json')),
      ),
      eventSourceProvider.overrideWithValue('sai/test'),
      secretStoreProvider.overrideWithValue(InMemorySecretStore()),
      builtinLlmsProvider.overrideWithValue([FakeLlmProvider.new]),
      defaultLlmIdProvider.overrideWithValue(null),
      // A home of its own: never the developer's Things container.
      environmentProvider.overrideWithValue({'HOME': tmp.path, ...environment}),
      ...overrides,
    ],
  );

  Future<int> lines(ProviderContainer c) async =>
      (await (await c.read(archiveProvider.future)).head()).count;

  group('thingsImportProvider (#40)', () {
    test('locate, preview, run, and a second preview finds nothing', () async {
      final path = seed(tasks: 2);
      final c = make(environment: {thingsDatabaseEnv: path});
      final n = c.read(thingsImportProvider.notifier);
      expect(c.read(thingsImportProvider), const ImportIdle());
      n.locate();
      expect(c.read(thingsImportProvider), ImportSource(path));

      await n.preview(const ThingsImportOptions());
      final planned = c.read(thingsImportProvider) as ImportPlanned;
      expect(planned.path, path);
      expect(planned.result.dryRun, isTrue);
      expect(planned.result.plan.length, 4);
      expect(planned.result.report.tasks.created, 2);
      expect(planned.result.report.unsupported[Unsupported.trashed], 1);
      expect(await lines(c), 0, reason: 'a preview writes nothing');

      final seen = <ThingsImportState>[];
      c.listen(thingsImportProvider, (_, s) => seen.add(s));
      await n.run();
      final done = c.read(thingsImportProvider) as ImportDone;
      expect(done.result.eventsAppended, 4);
      expect(await lines(c), 4);
      expect(seen.whereType<ImportRunning>(), isNotEmpty);
      expect(seen.whereType<ImportRunning>().last.done, 4);
      expect(seen.whereType<ImportRunning>().last.total, 4);

      await n.preview(const ThingsImportOptions());
      final again = c.read(thingsImportProvider) as ImportPlanned;
      expect(again.result.plan.isEmpty, isTrue);
      expect(again.result.report.tasks.unchanged, 2);
    });

    test('options reach the planner', () async {
      final path = p.join(tmp.path, 'main.sqlite');
      final f = ThingsFixture(path);
      f.item('Open', start: 1);
      f.item('Done', status: 3, stopped: DateTime.utc(2026, 8, 1));
      f.close();
      final c = make();
      final n = c.read(thingsImportProvider.notifier);
      n.useDatabase(path);
      await n.preview(const ThingsImportOptions(openOnly: true));
      final planned = c.read(thingsImportProvider) as ImportPlanned;
      expect(planned.result.report.tasks.created, 1);
      expect(planned.result.report.unsupported[Unsupported.openOnly], 1);
      expect(planned.options.openOnly, isTrue);
    });

    test('nothing to find is a failure with a next step, not a crash', () {
      final c = make();
      c.read(thingsImportProvider.notifier).locate();
      final failed = c.read(thingsImportProvider) as ImportFailed;
      expect(failed.failure, isA<ThingsNotFound>());
      expect(failed.path, isNull);
    });

    test('two databases are refused rather than guessed', () {
      for (final data in ['ThingsData-A', 'ThingsData-B']) {
        final dir = Directory(
          p.join(
            tmp.path,
            thingsContainerRelative,
            data,
            'Things Database.thingsdatabase',
          ),
        )..createSync(recursive: true);
        File(p.join(dir.path, 'main.sqlite')).writeAsStringSync('');
      }
      final c = make();
      c.read(thingsImportProvider.notifier).locate();
      final failed = c.read(thingsImportProvider) as ImportFailed;
      expect(failed.failure, isA<ThingsAmbiguous>());
    });

    test('a foreign file and a missing file fail by kind, path kept', () async {
      final foreign = File(p.join(tmp.path, 'x.sqlite'))
        ..writeAsStringSync('nope');
      final c = make();
      final n = c.read(thingsImportProvider.notifier);
      n.useDatabase(foreign.path);
      await n.preview(const ThingsImportOptions());
      var failed = c.read(thingsImportProvider) as ImportFailed;
      expect(failed.failure, isA<ThingsNotADatabase>());
      expect(failed.path, foreign.path);
      // A failed source can be replaced and previewed again.
      n.useDatabase(p.join(tmp.path, 'gone.sqlite'));
      await n.preview(const ThingsImportOptions());
      failed = c.read(thingsImportProvider) as ImportFailed;
      expect(failed.failure, isA<ThingsUnreadable>());
      expect(await lines(c), 0);
    });

    test('a run needs a preview first', () async {
      final c = make();
      final n = c.read(thingsImportProvider.notifier);
      n.useDatabase(seed());
      expect(n.run, throwsStateError);
    });

    test('only one run at a time; the second call is ignored', () async {
      final path = seed(tasks: 3);
      final c = make();
      final n = c.read(thingsImportProvider.notifier);
      n.useDatabase(path);
      await n.preview(const ThingsImportOptions());
      final first = n.run();
      final second = n.run();
      await Future.wait([first, second]);
      expect(
        (c.read(thingsImportProvider) as ImportDone).result.eventsAppended,
        5,
      );
      expect(await lines(c), 5);
    });

    test('reset drops a completion that lands afterwards', () async {
      final path = seed();
      final c = make(
        overrides: [
          thingsSnapshotReaderProvider.overrideWithValue((path) async {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            return readThingsSnapshot(path);
          }),
        ],
      );
      final n = c.read(thingsImportProvider.notifier);
      n.useDatabase(path);
      final preview = n.preview(const ThingsImportOptions());
      n.reset();
      await preview;
      expect(c.read(thingsImportProvider), const ImportIdle());
    });

    test('no state ever carries a title', () async {
      final path = seed();
      final c = make();
      final n = c.read(thingsImportProvider.notifier);
      final seen = <ThingsImportState>[];
      c.listen(thingsImportProvider, (_, s) => seen.add(s));
      n.useDatabase(path);
      await n.preview(const ThingsImportOptions());
      await n.run();
      for (final state in seen) {
        expect('$state', isNot(contains('oat milk')), reason: '$state');
        if (state is ImportPlanned) {
          for (final line in state.result.report.render()) {
            expect(line, isNot(contains('oat milk')));
          }
        }
      }
    });
  });
}
