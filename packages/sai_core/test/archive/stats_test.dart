import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late ProviderContainer container;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_archive_stats_test');
    container = ProviderContainer.test(
      overrides: [
        archiveRootProvider.overrideWithValue(Directory('${tmp.path}/archive')),
        settingsFileProvider.overrideWithValue(File('${tmp.path}/s.json')),
        eventSourceProvider.overrideWithValue('sai/test'),
        builtinLlmsProvider.overrideWithValue([FakeLlmProvider.new]),
        defaultLlmIdProvider.overrideWithValue(null),
      ],
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<TaskStore> store() async {
    await container.read(tasksProvider.future);
    return container.read(tasksProvider.notifier).store;
  }

  File dayFile() =>
      Directory('${tmp.path}/archive/events')
          .listSync()
          .whereType<File>()
          .single;

  group('archive stats (#40)', () {
    test('byteSize is what the day files hold; zero when empty', () async {
      final archive = await container.read(archiveProvider.future);
      expect(await archive.byteSize(), 0);
      final s = await store();
      await s.createTask(title: 'Buy oat milk');
      await s.createTask(title: 'Call mum');
      expect(await archive.byteSize(), dayFile().lengthSync());
    });

    test('archiveStatsProvider follows the log', () async {
      container.listen(archiveStatsProvider, (_, _) {});
      var stats = await container.read(archiveStatsProvider.future);
      expect(stats.count, 0);
      expect(stats.bytes, 0);
      final s = await store();
      await s.createTask(title: 'Buy oat milk');
      stats = await container.read(archiveStatsProvider.future);
      expect(stats.count, 1);
      expect(stats.bytes, dayFile().lengthSync());
    });
  });

  group('archiveRevisionProvider (#40)', () {
    test('a bump re-reads the stats and the line count', () async {
      container.listen(archiveStatsProvider, (_, _) {});
      container.listen(archiveLineCountProvider, (_, _) {});
      expect((await container.read(archiveStatsProvider.future)).count, 0);
      // A writer the watchers cannot see: the recorder, straight in.
      final recorder = await container.read(llmRecorderProvider.future);
      final call = await recorder.start(
        container.read(llmRegistryProvider)['fake']!,
        providerTestRequest(reasoning: false),
      );
      await call.done;
      expect((await container.read(archiveStatsProvider.future)).count, 0);
      container.read(archiveRevisionProvider.notifier).bump();
      final stats = await container.read(archiveStatsProvider.future);
      expect(stats.count, greaterThan(0));
      expect(
        await container.read(archiveLineCountProvider.future),
        stats.count,
      );
    });
  });

  group('archiveVerifyProvider (#40)', () {
    test('a healthy archive verifies to its count', () async {
      final s = await store();
      await s.createTask(title: 'Buy oat milk');
      expect(container.read(archiveVerifyProvider), const VerifyIdle());
      final n = container.read(archiveVerifyProvider.notifier);
      final done = n.verify();
      expect(container.read(archiveVerifyProvider), const VerifyRunning());
      await done;
      expect(container.read(archiveVerifyProvider), const Verified(1));
    });

    test('a flipped byte fails once, names the file, never a line', () async {
      final s = await store();
      await s.createTask(title: 'Buy oat milk');
      final day = dayFile();
      final text = day.readAsStringSync();
      day.writeAsStringSync(text.replaceFirst('Buy', 'Bxy'));
      final n = container.read(archiveVerifyProvider.notifier);
      await n.verify();
      final failed = container.read(archiveVerifyProvider) as VerifyFailed;
      expect(failed.message, isNot(contains('oat milk')));
      expect(failed.message, isNot(contains(tmp.path)));
      // A flipped byte changes a line's id, so the chain and HEAD no
      // longer agree; the message names HEAD, not a path.
      expect(failed.message, contains('HEAD'));
      // No retry storm: the state is failed now, not after ten walks.
      expect(container.read(archiveVerifyProvider), same(failed));
    });

    test('one walk at a time', () async {
      final s = await store();
      await s.createTask(title: 'Buy oat milk');
      final n = container.read(archiveVerifyProvider.notifier);
      final seen = <VerifyState>[];
      container.listen(archiveVerifyProvider, (_, v) => seen.add(v));
      await Future.wait([n.verify(), n.verify()]);
      expect(seen.whereType<VerifyRunning>(), hasLength(1));
      expect(seen.last, const Verified(1));
    });
  });
}
