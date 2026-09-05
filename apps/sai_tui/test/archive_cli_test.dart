import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:sai_tui/cli.dart';
import 'package:test/test.dart';

import 'pump.dart';

void main() {
  late ProviderContainer container;
  late StringBuffer out;
  late StringBuffer err;
  late Directory scratch;

  setUp(() {
    container = testContainer(finishedTasks: null);
    out = StringBuffer();
    err = StringBuffer();
    scratch = Directory.systemTemp.createTempSync('sai_archive_cli_test');
    addTearDown(() => scratch.deleteSync(recursive: true));
  });

  Future<int> run(String line) => runCli(
    line.split(' '),
    container: container,
    out: out,
    err: err,
    readSecret: (_) => null,
    readLine: (_) => null,
  );

  Directory root() => container.read(archiveRootProvider);
  String replica() => '${scratch.path}/replica';

  Future<void> capture(String title) async {
    await container.read(tasksProvider.future);
    await container.read(tasksProvider.notifier).store.createTask(title: title);
  }

  group('archive verify', () {
    test('walks the live log and names its head', () async {
      await capture('Buy oat milk');
      expect(await run('archive verify'), cliOk);
      expect(
        out.toString(),
        matches(r'^verified: 1 lines, head sha256-[a-f0-9]{64}\n$'),
      );
      expect(err.toString(), isEmpty);
    });

    test('an empty log verifies as none', () async {
      expect(await run('archive verify'), cliOk);
      expect(out.toString(), 'verified: 0 lines, head none\n');
    });

    test('a flipped byte fails by file, never by line', () async {
      await capture('Buy oat milk');
      await capture('two');
      final day = Directory('${root().path}/events')
          .listSync()
          .whereType<File>()
          .single;
      day.writeAsStringSync(day.readAsStringSync().replaceFirst('oat', 'oxt'));
      expect(await run('archive verify'), cliFailed);
      expect(err.toString(), startsWith('sai_tui: failed: chain broken'));
      expect(err.toString(), contains('.jsonl:2'));
      expect(err.toString(), isNot(contains('oat')));
      expect(err.toString(), isNot(contains(root().path)));
    });

    test('a root that is not there is no archive, and is not made', () async {
      final nowhere = '${scratch.path}/nowhere';
      expect(await run('archive verify $nowhere'), cliFailed);
      expect(err.toString(), 'sai_tui: no archive at $nowhere\n');
      expect(Directory(nowhere).existsSync(), isFalse);
      Directory(nowhere).createSync();
      expect(await run('archive verify $nowhere'), cliFailed);
      expect(File('$nowhere/MANIFEST.json').existsSync(), isFalse);
    });

    test('takes another root', () async {
      await capture('one');
      expect(await run('archive backup ${replica()}'), cliOk);
      out.clear();
      expect(await run('archive verify ${replica()}'), cliOk);
      expect(out.toString(), startsWith('verified: 1 lines'));
      expect(await run('archive verify ${replica()} extra'), cliUsageError);
    });
  });

  group('archive backup-dir', () {
    test('shows, sets and clears the destination', () async {
      expect(await run('archive backup-dir'), cliOk);
      expect(out.toString(), 'backup destination: none\n');
      out.clear();
      expect(await run('archive backup-dir ${replica()}'), cliOk);
      expect(out.toString(), 'backup destination: ${replica()}\n');
      expect(container.read(settingsProvider).archiveBackup, replica());
      expect(
        File(container.read(settingsFileProvider).path).readAsStringSync(),
        contains('"archive_backup":"${replica()}"'),
      );
      out.clear();
      expect(await run('archive backup-dir none'), cliOk);
      expect(out.toString(), 'backup destination: none\n');
      expect(container.read(settingsProvider).archiveBackup, isNull);
    });

    test('refuses a relative path and a place inside the log', () async {
      expect(await run('archive backup-dir backup'), cliFailed);
      expect(
        err.toString(),
        'sai_tui: the backup destination must be absolute\n',
      );
      err.clear();
      expect(
        await run('archive backup-dir ${root().path}/events/copy'),
        cliFailed,
      );
      expect(err.toString(), contains('inside the archive'));
      expect(container.read(settingsProvider).archiveBackup, isNull);
      expect(await run('archive backup-dir a b'), cliUsageError);
    });
  });

  group('archive backup', () {
    test('says so while nothing is configured, and exits clean', () async {
      expect(await run('archive backup'), cliOk);
      expect(
        out.toString(),
        'no backup destination configured; set one with: sai_tui archive '
        'backup-dir <dir>\n',
      );
      expect(Directory(replica()).existsSync(), isFalse);
    });

    test('copies to the configured destination and reports', () async {
      await capture('one');
      await capture('two');
      expect(await run('archive backup-dir ${replica()}'), cliOk);
      out.clear();
      expect(await run('archive backup'), cliOk);
      expect(
        out.toString(),
        matches(
          r'^backed up: 2 lines to .*/replica \(1 files, \d+ bytes copied\)\n$',
        ),
      );
      final check = await Archive.open(Directory(replica()));
      expect((await check.verify()).count, 2);
      await check.close();
      out.clear();
      expect(await run('archive backup'), cliOk);
      expect(out.toString(), contains('(0 files, 0 bytes copied)'));
    });

    test('copies to a directory given on the line', () async {
      await capture('one');
      expect(await run('archive backup ${replica()}'), cliOk);
      expect(out.toString(), startsWith('backed up: 1 lines to ${replica()}'));
      expect(container.read(settingsProvider).archiveBackup, isNull);
      expect(await run('archive backup relative/dir'), cliFailed);
      expect(await run('archive backup a b'), cliUsageError);
    });

    test('an unmounted destination is skipped, exit 0', () async {
      final gone = '${scratch.path}/Volumes/Backup/sai';
      expect(await run('archive backup-dir $gone'), cliOk);
      out.clear();
      expect(await run('archive backup'), cliOk);
      expect(
        out.toString(),
        'backup skipped: $gone — the destination is not mounted (its parent does not exist)\n',
      );
      expect(err.toString(), isEmpty);
      expect(Directory('${scratch.path}/Volumes').existsSync(), isFalse);
    });

    test('a diverged replica fails, exit 1', () async {
      await capture('one');
      expect(await run('archive backup ${replica()}'), cliOk);
      final day = Directory('${replica()}/events')
          .listSync()
          .whereType<File>()
          .single;
      day.writeAsStringSync('{"more":1}\n', mode: FileMode.append);
      expect(await run('archive backup ${replica()}'), cliFailed);
      expect(
        err.toString(),
        startsWith('sai_tui: backup failed: the replica has diverged'),
      );
    });
  });

  group('archive restore', () {
    test('puts a replica back into an absent log, then verifies', () async {
      await capture('one');
      await capture('two');
      expect(await run('archive backup ${replica()}'), cliOk);
      out.clear();
      // A fresh container over an empty root: the drill's "wipe".
      final wiped = Directory('${scratch.path}/wiped');
      container = testContainer(finishedTasks: null, archiveRoot: wiped);
      expect(await run('archive restore ${replica()}'), cliOk);
      expect(
        out.toString(),
        'restored: 2 lines into ${wiped.path}, every hash checked\n',
      );
      out.clear();
      expect(await run('archive verify'), cliOk);
      expect(out.toString(), startsWith('verified: 2 lines'));
      await container.read(tasksProvider.future);
      expect(container.read(tasksProvider).requireValue.tasks, hasLength(2));
    });

    test('refuses a log that holds events', () async {
      await capture('one');
      expect(await run('archive backup ${replica()}'), cliOk);
      expect(await run('archive restore ${replica()}'), cliFailed);
      expect(
        err.toString(),
        'sai_tui: restore failed: the archive root is not empty: move it aside, then restore\n',
      );
    });

    test('refuses what is not a replica', () async {
      expect(await run('archive restore ${scratch.path}'), cliFailed);
      expect(err.toString(), contains('not an archive'));
      expect(await run('archive restore'), cliUsageError);
    });
  });

  test('archive alone is a usage error', () async {
    expect(await run('archive'), cliUsageError);
    expect(await run('archive frob'), cliUsageError);
    expect(
      err.toString(),
      contains('archive takes backup, backup-dir, verify or restore'),
    );
  });
}
