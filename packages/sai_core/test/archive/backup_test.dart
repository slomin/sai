import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  group('the archive backup (#15)', () {
    late Directory tmp;
    late Directory replica;
    final at = DateTime.utc(2026, 8, 24, 12);

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('sai_backup_test');
      replica = Directory('${tmp.path}/replica');
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    Future<ProviderContainer> make({
      String? destination,
      Duration? debounce,
      List<Override> overrides = const [],
    }) async {
      final settings = File('${tmp.path}/settings.json');
      if (destination != null) {
        settings.writeAsStringSync(
          Settings.empty.withArchiveBackup(destination).encode(),
        );
      }
      final container = ProviderContainer.test(
        overrides: [
          archiveRootProvider.overrideWithValue(
            Directory('${tmp.path}/archive'),
          ),
          settingsFileProvider.overrideWithValue(settings),
          eventSourceProvider.overrideWithValue('sai/test'),
          secretStoreProvider.overrideWithValue(InMemorySecretStore()),
          builtinLlmsProvider.overrideWithValue([FakeLlmProvider.new]),
          defaultLlmIdProvider.overrideWithValue(null),
          clockProvider.overrideWithValue(() => at),
          connectionProbeEveryProvider.overrideWithValue(null),
          archivePollEveryProvider.overrideWithValue(null),
          archiveBackupDebounceProvider.overrideWithValue(debounce),
          ...overrides,
        ],
      );
      container.listen(archiveBackupProvider, (_, _) {});
      await container.read(tasksProvider.future);
      return container;
    }

    test('idle without a destination: a request copies nothing', () async {
      final container = await make();
      expect(container.read(archiveBackupProvider), const BackupIdle());
      await container.read(archiveBackupProvider.notifier).backupNow();
      expect(container.read(archiveBackupProvider), const BackupIdle());
      expect(replica.existsSync(), isFalse);
    });

    test('a request copies the log and reports the count', () async {
      final container = await make(destination: replica.path);
      await container
          .read(tasksProvider.notifier)
          .store
          .createTask(title: 'one');
      await container.read(archiveBackupProvider.notifier).backupNow();
      expect(container.read(archiveBackupProvider), BackedUp(count: 1, at: at));
      final check = await Archive.open(replica);
      expect((await check.verify()).count, 1);
      await check.close();
    });

    test('a line the log gains re-arms the copy', () async {
      final container = await make(
        destination: replica.path,
        debounce: const Duration(milliseconds: 40),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        container.read(archiveBackupProvider),
        BackedUp(count: 0, at: at),
        reason: 'the first copy after a start',
      );
      await container
          .read(tasksProvider.notifier)
          .store
          .createTask(title: 'one');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(container.read(archiveBackupProvider), BackedUp(count: 1, at: at));
    });

    test('a request during a copy joins it and copies once more', () async {
      final container = await make(destination: replica.path);
      final store = container.read(tasksProvider.notifier).store;
      await store.createTask(title: 'one');
      final backup = container.read(archiveBackupProvider.notifier);
      final first = backup.backupNow();
      await store.createTask(title: 'two');
      final second = backup.backupNow();
      expect(identical(first, second), isTrue);
      await first;
      // The dirty flag re-arms through the debounce, which is off here:
      // a second explicit request lands the second line.
      await backup.backupNow();
      expect(container.read(archiveBackupProvider), BackedUp(count: 2, at: at));
    });

    test('an unmounted destination is skipped, not failed', () async {
      final container = await make(
        destination: '${tmp.path}/Volumes/Backup/sai',
      );
      await container.read(archiveBackupProvider.notifier).backupNow();
      expect(
        container.read(archiveBackupProvider),
        isA<BackupSkipped>().having(
          (s) => s.reason,
          'reason',
          contains('not mounted'),
        ),
      );
      expect(Directory('${tmp.path}/Volumes').existsSync(), isFalse);
    });

    test('a diverged replica fails in words with no path', () async {
      final container = await make(destination: replica.path);
      final backup = container.read(archiveBackupProvider.notifier);
      await backup.backupNow();
      final other = await Archive.open(Directory('${tmp.path}/other'));
      await other.close();
      File('${replica.path}/MANIFEST.json').writeAsStringSync(
        File('${tmp.path}/other/MANIFEST.json').readAsStringSync(),
      );
      await backup.backupNow();
      final state = container.read(archiveBackupProvider);
      expect(state, isA<BackupFailed>());
      final message = (state as BackupFailed).message;
      expect(message, contains('another archive'));
      expect(message, isNot(contains(tmp.path)));
    });

    test('a corrupt replica names a file, never a line', () async {
      final container = await make(destination: replica.path);
      await container
          .read(tasksProvider.notifier)
          .store
          .createTask(title: 'Buy oat milk');
      final backup = container.read(archiveBackupProvider.notifier);
      await backup.backupNow();
      final day = Directory('${replica.path}/events')
          .listSync()
          .whereType<File>()
          .single;
      day.writeAsStringSync(day.readAsStringSync().replaceFirst('oat', 'oxt'));
      await backup.backupNow();
      final state = container.read(archiveBackupProvider);
      expect(state, isA<BackupFailed>());
      final message = (state as BackupFailed).message;
      expect(message, contains('.jsonl'));
      expect(message, isNot(contains('oat')));
      expect(message, isNot(contains(tmp.path)));
    });

    test('an archive that cannot open fails the backup, in words', () async {
      final root = Directory('${tmp.path}/archive')..createSync();
      File('${root.path}/MANIFEST.json').writeAsStringSync('not json\n');
      final settings = File('${tmp.path}/settings.json')
        ..writeAsStringSync(
          Settings.empty.withArchiveBackup(replica.path).encode(),
        );
      // A failed provider is retried with backoff before its future
      // rejects; the copy must see the rejection, not wait on the retry.
      final container = ProviderContainer.test(
        retry: (count, error) => null,
        overrides: [
          archiveRootProvider.overrideWithValue(root),
          settingsFileProvider.overrideWithValue(settings),
          eventSourceProvider.overrideWithValue('sai/test'),
          secretStoreProvider.overrideWithValue(InMemorySecretStore()),
          builtinLlmsProvider.overrideWithValue([FakeLlmProvider.new]),
          defaultLlmIdProvider.overrideWithValue(null),
          clockProvider.overrideWithValue(() => at),
          connectionProbeEveryProvider.overrideWithValue(null),
          archivePollEveryProvider.overrideWithValue(null),
          archiveBackupDebounceProvider.overrideWithValue(null),
        ],
      );
      container.listen(archiveBackupProvider, (_, _) {});
      await container.read(archiveBackupProvider.notifier).backupNow();
      final state = container.read(archiveBackupProvider);
      expect(state, isA<BackupFailed>());
      final message = (state as BackupFailed).message;
      expect(message, contains('MANIFEST.json'));
      expect(message, isNot(contains(tmp.path)));
      expect(replica.existsSync(), isFalse);
    });

    test('the timer follows archiveBackupDebounceProvider and disposal', () {
      expect(ArchiveBackup.debounce, const Duration(seconds: 30));
      final settings = File('${tmp.path}/settings.json')
        ..writeAsStringSync(
          Settings.empty.withArchiveBackup(replica.path).encode(),
        );
      fakeAsync((async) {
        final container = ProviderContainer.test(
          overrides: [
            settingsFileProvider.overrideWithValue(settings),
            builtinLlmsProvider.overrideWithValue([FakeLlmProvider.new]),
            defaultLlmIdProvider.overrideWithValue(null),
            tasksProvider.overrideWith(_StuckTasks.new),
          ],
        );
        final sub = container.listen(archiveBackupProvider, (_, _) {});
        expect(async.nonPeriodicTimerCount, 1);
        sub.close();
        container.dispose();
        expect(async.pendingTimers, isEmpty);

        final quiet = ProviderContainer.test(
          overrides: [
            settingsFileProvider.overrideWithValue(settings),
            builtinLlmsProvider.overrideWithValue([FakeLlmProvider.new]),
            defaultLlmIdProvider.overrideWithValue(null),
            tasksProvider.overrideWith(_StuckTasks.new),
            archiveBackupDebounceProvider.overrideWithValue(null),
          ],
        );
        quiet.listen(archiveBackupProvider, (_, _) {});
        expect(async.pendingTimers, isEmpty);
        quiet.dispose();
      });
    });

    test('clearing the destination goes idle', () async {
      final container = await make(destination: replica.path);
      await container.read(archiveBackupProvider.notifier).backupNow();
      expect(container.read(archiveBackupProvider), isA<BackedUp>());
      container.read(settingsProvider.notifier).setArchiveBackup(null);
      expect(container.read(archiveBackupProvider), const BackupIdle());
    });

    test('BackupState compares by value', () {
      expect(const BackupIdle(), const BackupIdle());
      expect(const BackupRunning(), isNot(const BackupIdle()));
      expect(BackedUp(count: 1, at: at), BackedUp(count: 1, at: at));
      expect(BackedUp(count: 1, at: at), isNot(BackedUp(count: 2, at: at)));
      expect(const BackupSkipped('x'), const BackupSkipped('x'));
      expect(const BackupFailed('x'), isNot(const BackupFailed('y')));
      expect('${BackedUp(count: 3, at: at)}', contains('3'));
    });
  });
}

/// A task store that never opens, so a timer test runs no file I/O.
class _StuckTasks extends TasksNotifier {
  @override
  Future<TaskProjection> build() => Completer<TaskProjection>().future;
}
