import 'dart:convert';
import 'dart:io';

import 'package:sai_core/src/process/lock.dart';
import 'package:test/test.dart';

import '../package_root.dart';

/// The lock is what keeps the app and the terminal client from running
/// two App Servers on one credential home. POSIX locks are per process,
/// so the proof needs a second Dart VM — the one spawn this file makes
/// (`no_spawn_test` lists it).
void main() {
  late Directory tmp;
  late String probe;

  setUpAll(() async {
    probe = '${(await packageRoot()).path}/test/process/lock_probe.dart';
  });

  setUp(() => tmp = Directory.systemTemp.createTempSync('sai_lock'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<Process> holder(File file) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      probe,
      file.path,
    ], workingDirectory: (await packageRoot()).path);
    final first = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    expect(first, 'held');
    return process;
  }

  test(
    'a lock another process holds is busy here, and free once released',
    () async {
      final file = File('${tmp.path}/lock');
      final other = await holder(file);
      try {
        expect(await ExclusiveLock.tryAcquire(file), isNull);
      } finally {
        await other.stdin.close();
        expect(await other.exitCode, 0);
      }
      final mine = await ExclusiveLock.tryAcquire(file);
      expect(mine, isNotNull);
      expect(mine!.isHeld, isTrue);
      await mine.release();
      expect(mine.isHeld, isFalse);
      await mine.release();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('a lock held here is busy for another process', () async {
    final file = File('${tmp.path}/lock');
    final mine = await ExclusiveLock.tryAcquire(file);
    expect(mine, isNotNull);
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      probe,
      file.path,
    ], workingDirectory: (await packageRoot()).path);
    expect(result.stdout.toString().trim(), 'busy');
    await mine!.release();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('an unopenable file is not a lock', () async {
    expect(
      await ExclusiveLock.tryAcquire(File('${tmp.path}/missing/dir/lock')),
      isNull,
    );
  });
}
