import 'dart:convert';
import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:sai_core/things_testing.dart';
import 'package:sai_tui/cli.dart';
import 'package:test/test.dart';

import 'pump.dart';

void main() {
  late Directory tmp;
  late ProviderContainer container;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_tui_things_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // A home of its own: the locator must never wander into the
    // developer's real Things container from a test.
    container = testContainer(
      overrides: [
        environmentProvider.overrideWithValue({'HOME': tmp.path}),
      ],
    );
    out = StringBuffer();
    err = StringBuffer();
  });

  Future<int> run(String line) => runCli(
    line.split(' '),
    container: container,
    out: out,
    err: err,
    readSecret: (_) => null,
  );

  String seed() {
    final path = '${tmp.path}/main.sqlite';
    final f = ThingsFixture(path);
    final home = f.area('Home');
    final kitchen = f.project('Kitchen', area: home, start: 1);
    f.item('Buy oat milk', project: kitchen, start: 1);
    f.item('Old', trashed: true);
    f.close();
    return path;
  }

  test('--dry-run lists the operations and writes nothing', () async {
    final path = seed();
    expect(await run('things import --dry-run --db $path'), cliOk);
    final lines = out.toString().trim().split('\n');
    expect(
      lines.first,
      'things import (dry run): $path '
      '(mapping verified against Things $thingsVerifiedVersion)',
    );
    expect(lines, contains('+ area "Home" (area-001)'));
    expect(lines, contains('+ project "Kitchen" (project-002)'));
    expect(lines, contains('+ task "Buy oat milk" (task-003)'));
    expect(lines, contains('  tasks: 1 created, 0 updated, 0 unchanged'));
    expect(lines, contains('  ${Unsupported.trashed}: 1'));
    expect(lines.last, '3 operations would run; nothing written');
    expect(archiveLines(container), isEmpty);
    expect(err.toString(), isEmpty);
  });

  test(
    'a run appends system events; a second run finds nothing to do',
    () async {
      final path = seed();
      expect(await run('things import --db $path'), cliOk);
      final lines = archiveLines(container);
      expect(lines, hasLength(3));
      for (final line in lines) {
        final event = jsonDecode(line) as Map<String, Object?>;
        expect(event['actor'], 'system');
        expect(event['source'], EventSources.tui);
        expect((event['payload'] as Map)['external'], isNotNull);
      }
      expect(out.toString(), contains('3 operations, 3 events appended in'));
      // The dry-run listing is the only place a title is printed.
      expect(out.toString(), isNot(contains('Buy oat milk')));

      out.clear();
      expect(await run('things import --db $path'), cliOk);
      expect(archiveLines(container), hasLength(3));
      expect(
        out.toString().trim().split('\n').last,
        'nothing to do — sai already matches Things',
      );
    },
  );

  test('the database is found through SAI_THINGS_DB', () async {
    final path = seed();
    container = testContainer(
      overrides: [
        environmentProvider.overrideWithValue({
          'HOME': tmp.path,
          thingsDatabaseEnv: path,
        }),
      ],
    );
    expect(await run('things import --dry-run'), cliOk);
    expect(out.toString(), contains('3 operations would run'));
  });

  test('no database is a failure with a fixed message, not a crash', () async {
    expect(await run('things import'), cliFailed);
    expect(
      err.toString().trim(),
      'sai_tui: no Things 3 database found; pass --db <main.sqlite> '
      'or set $thingsDatabaseEnv',
    );
    expect(archiveLines(container), isEmpty);
  });

  test('a missing file and a foreign database fail cleanly', () async {
    final missing = '${tmp.path}/nope.sqlite';
    expect(await run('things import --db $missing'), cliFailed);
    expect(
      err.toString().trim(),
      'sai_tui: cannot read the Things database at $missing',
    );
    err.clear();
    final foreign = '${tmp.path}/foreign.sqlite';
    File(foreign).writeAsBytesSync(List.filled(4096, 0));
    expect(await run('things import --db $foreign'), cliFailed);
    expect(err.toString(), startsWith('sai_tui: '));
    expect(archiveLines(container), isEmpty);
  });

  test('bad options are usage errors', () async {
    expect(await run('things import --db'), cliUsageError);
    expect(err.toString(), contains('--db needs a path'));
    err.clear();
    expect(await run('things import --force'), cliUsageError);
    expect(err.toString(), contains('unknown option: --force'));
  });
}
