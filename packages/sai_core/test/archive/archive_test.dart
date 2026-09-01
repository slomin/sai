import 'dart:convert';
import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  var nowMicros = DateTime.utc(2026, 8, 23, 10).microsecondsSinceEpoch;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_archive_test');
    nowMicros = DateTime.utc(2026, 8, 23, 10).microsecondsSinceEpoch;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  DateTime clock() {
    nowMicros += 1000;
    return DateTime.fromMicrosecondsSinceEpoch(nowMicros, isUtc: true);
  }

  EventDraft draft([String text = 'hello']) => EventDraft(
    type: EventTypes.chatMessage,
    actor: Actor.user,
    source: 'sai/tui',
    payload: {'text': text},
  );

  File dayFile(String day) => File('${tmp.path}/events/$day.jsonl');

  test('the first event is genesis: prev is null, HEAD counts one', () async {
    final archive = await Archive.open(tmp, clock: clock);
    final stored = await archive.append(draft());
    final line = dayFile('2026-08-23').readAsStringSync().trimRight();
    expect(line, contains('"prev":null'));
    expect(stored.id, BlobRef.sha256OfBytes(utf8.encode(line)));
    expect(stored.event.prev, isNull);
    final report = await archive.verify();
    expect(report.count, 1);
    expect(report.head, stored.id);
  });

  test('head() is the cheap read of HEAD and follows another writer', () async {
    final archive = await Archive.open(tmp, clock: clock);
    expect((await archive.head()).count, 0);
    await archive.append(draft());
    final other = await Archive.open(tmp, clock: clock);
    await other.append(draft('from another process'));
    final head = await archive.head();
    final report = await archive.verify();
    expect(head.count, 2);
    expect(head.head, report.head);
    await other.close();
  });

  test('appended counts this instance\'s appends only (#118)', () async {
    final archive = await Archive.open(tmp, clock: clock);
    expect(archive.appended, 0);
    await archive.append(draft());
    expect(archive.appended, 1);
    final other = await Archive.open(tmp, clock: clock);
    await other.append(draft('from another process'));
    expect(archive.appended, 1, reason: 'another writer moves HEAD only');
    expect(other.appended, 1);
    expect((await archive.head()).count, 2);
    // A refused append advances neither.
    await expectLater(
      archive.append(draft(), validate: (_) => throw StateError('no')),
      throwsStateError,
    );
    expect(archive.appended, 1);
    expect((await archive.head()).count, 2);
    await other.close();
  });

  test('pre-write validation sees the final event and is atomic', () async {
    final archive = await Archive.open(tmp, clock: clock);
    final first = await archive.append(draft('first'));
    final day = dayFile('2026-08-23');
    final linesBefore = day.readAsBytesSync();
    final headBefore = File('${tmp.path}/HEAD').readAsBytesSync();
    final explicitTs = DateTime.utc(2026, 8, 23, 9);
    StoredEvent? seen;

    await expectLater(
      archive.append(
        EventDraft(
          type: EventTypes.chatMessage,
          actor: Actor.user,
          source: 'sai/tui',
          payload: {'text': 'rejected'},
          ts: explicitTs,
        ),
        validate: (stored) {
          seen = stored;
          throw const FormatException('rejected');
        },
      ),
      throwsFormatException,
    );

    expect(seen, isNotNull);
    expect(seen!.event.prev, first.id);
    expect(seen!.event.ts, explicitTs);
    expect(seen!.id, seen!.event.deriveId());
    expect(day.readAsBytesSync(), linesBefore);
    expect(File('${tmp.path}/HEAD').readAsBytesSync(), headBefore);
    expect((await archive.verify()).count, 1);
  });

  test('the chain crosses a day rollover and reads back in order', () async {
    final archive = await Archive.open(tmp, clock: clock);
    final ids = <BlobRef>[];
    for (var i = 0; i < 3; i++) {
      ids.add((await archive.append(draft('day1 #$i'))).id);
    }
    nowMicros = DateTime.utc(2026, 8, 24, 9).microsecondsSinceEpoch;
    for (var i = 0; i < 2; i++) {
      ids.add((await archive.append(draft('day2 #$i'))).id);
    }
    expect(dayFile('2026-08-23').existsSync(), isTrue);
    expect(dayFile('2026-08-24').existsSync(), isTrue);

    final events = await archive.events().toList();
    expect(events.map((e) => e.id).toList(), ids);
    expect(events.first.event.prev, isNull);
    for (var i = 1; i < events.length; i++) {
      expect(events[i].event.prev, ids[i - 1]);
    }
    expect((await archive.verify()).count, 5);
  });

  test(
    'a flipped byte mid-file is corruption, named by file and line',
    () async {
      final archive = await Archive.open(tmp, clock: clock);
      for (var i = 0; i < 3; i++) {
        await archive.append(draft('#$i'));
      }
      final day = dayFile('2026-08-23');
      final lines = day.readAsStringSync().trimRight().split('\n');
      lines[1] = lines[1].replaceFirst('"text":"#1"', '"text":"#!"');
      day.writeAsStringSync('${lines.join('\n')}\n');

      await expectLater(
        archive.events().toList(),
        throwsA(
          isA<ArchiveCorruptionError>()
              .having((e) => e.file, 'file', endsWith('2026-08-23.jsonl'))
              .having((e) => e.line, 'line', 3),
        ),
      );
    },
  );

  test('a deleted interior line breaks the chain', () async {
    final archive = await Archive.open(tmp, clock: clock);
    for (var i = 0; i < 3; i++) {
      await archive.append(draft('#$i'));
    }
    final day = dayFile('2026-08-23');
    final lines = day.readAsStringSync().trimRight().split('\n');
    day.writeAsStringSync('${lines[0]}\n${lines[2]}\n');
    await expectLater(
      archive.events().toList(),
      throwsA(isA<ArchiveCorruptionError>().having((e) => e.line, 'line', 2)),
    );
  });

  test(
    'whole trailing lines cut off no longer match HEAD: open refuses',
    () async {
      final archive = await Archive.open(tmp, clock: clock);
      for (var i = 0; i < 3; i++) {
        await archive.append(draft('#$i'));
      }
      final day = dayFile('2026-08-23');
      final lines = day.readAsStringSync().trimRight().split('\n');
      day.writeAsStringSync('${lines[0]}\n');
      expect(
        () => Archive.open(tmp, clock: clock),
        throwsA(isA<ArchiveCorruptionError>()),
      );
    },
  );

  group('torn tail', () {
    test('is loud on read and append, and repairable', () async {
      var archive = await Archive.open(tmp, clock: clock);
      await archive.append(draft('#0'));
      await archive.append(draft('#1'));
      final day = dayFile('2026-08-23');
      final cleanLength = day.lengthSync();
      day.writeAsStringSync('{"torn', mode: FileMode.append);

      // Reopen: readable up to the tear, loud about the tear itself.
      archive = await Archive.open(tmp, clock: clock);
      final seen = <StoredEvent>[];
      await expectLater(
        () async {
          await for (final e in archive.events()) {
            seen.add(e);
          }
        }(),
        throwsA(
          isA<TornTailError>()
              .having((e) => e.offset, 'offset', cleanLength)
              .having((e) => e.file, 'file', endsWith('2026-08-23.jsonl')),
        ),
      );
      expect(seen, hasLength(2));
      await expectLater(
        archive.append(draft('#2')),
        throwsA(isA<TornTailError>()),
      );

      // The documented repair: truncate the bytes that never became an event.
      day.openSync(mode: FileMode.append)
        ..truncateSync(cleanLength)
        ..closeSync();
      await archive.append(draft('#2'));
      expect((await archive.verify()).count, 3);
    });
  });

  test(
    'HEAD one behind (crash between append and rename) rolls forward',
    () async {
      final archive = await Archive.open(tmp, clock: clock);
      await archive.append(draft('#0'));
      final headBefore = File('${tmp.path}/HEAD').readAsStringSync();
      await archive.append(draft('#1'));
      File('${tmp.path}/HEAD')
          .writeAsStringSync(headBefore); // simulate the crash

      final reopened = await Archive.open(tmp, clock: clock);
      final report = await reopened.verify();
      expect(report.count, 2);
      final head = jsonDecode(
        File('${tmp.path}/HEAD').readAsStringSync(),
      ) as Map<String, Object?>;
      expect(head['count'], 2);
    },
  );

  test('two instances in one process interleave safely', () async {
    final a = await Archive.open(tmp, clock: clock);
    final b = await Archive.open(tmp, clock: clock);
    await Future.wait([
      for (var i = 0; i < 10; i++) ...[
        a.append(draft('a#$i')),
        b.append(draft('b#$i')),
      ],
    ]);
    expect((await a.verify()).count, 20);
    expect((await b.verify()).count, 20);
  });

  test('an event newer than its day file is corruption', () async {
    final archive = await Archive.open(tmp, clock: clock);
    await archive.append(draft());
    dayFile('2026-08-23').renameSync(dayFile('2026-08-22').path);
    await expectLater(
      archive.events().toList(),
      throwsA(
        isA<ArchiveCorruptionError>().having(
          (e) => e.reason,
          'reason',
          contains('newer than its day file'),
        ),
      ),
    );
  });

  test('a backdated ts (backwards clock) files under the newest day', () async {
    final archive = await Archive.open(tmp, clock: clock);
    await archive.append(draft());
    final stale = EventDraft(
      type: EventTypes.chatMessage,
      actor: Actor.user,
      source: 'sai/tui',
      payload: {'text': 'yesterday'},
      ts: DateTime.utc(2026, 8, 22, 12),
    );
    final stored = await archive.append(stale);
    expect(stored.event.tsText, startsWith('2026-08-22'));
    expect(dayFile('2026-08-22').existsSync(), isFalse);
    expect((await archive.verify()).count, 2);
  });

  test(
    'a ts outside four-digit years is refused before anything is written',
    () async {
      final archive = await Archive.open(tmp, clock: clock);
      final farFuture = EventDraft(
        type: EventTypes.chatMessage,
        actor: Actor.user,
        source: 'sai/tui',
        payload: {'text': 'unit mix-up'},
        ts: DateTime.fromMicrosecondsSinceEpoch(
          DateTime.utc(9999, 12, 31).microsecondsSinceEpoch * 1000,
          isUtc: true,
        ),
      );
      await expectLater(archive.append(farFuture), throwsArgumentError);
      expect((await archive.verify()).count, 0);
    },
  );

  test('a zero-length day file is ignored, and appends carry on', () async {
    final archive = await Archive.open(tmp, clock: clock);
    await archive.append(draft());
    dayFile('2026-08-23')
        .writeAsStringSync(''); // interrupted-first-write trace
    // Its event is gone, so HEAD no longer matches: loud, not silent.
    await expectLater(
      Archive.open(tmp, clock: clock),
      throwsA(isA<ArchiveCorruptionError>()),
    );
    // But a fresh root with only a zero-length file is simply empty.
    final tmp2 = Directory.systemTemp.createTempSync('sai_archive_test');
    addTearDown(() => tmp2.deleteSync(recursive: true));
    final fresh = await Archive.open(tmp2, clock: clock);
    File('${tmp2.path}/events/2026-08-23.jsonl').writeAsStringSync('');
    await fresh.append(draft());
    expect((await fresh.verify()).count, 1);
  });

  test('HEAD several events behind a truthful chain rolls forward', () async {
    final archive = await Archive.open(tmp, clock: clock);
    await archive.append(draft('#0'));
    final headBefore = File('${tmp.path}/HEAD').readAsStringSync();
    await archive.append(draft('#1'));
    await archive.append(draft('#2'));
    File('${tmp.path}/HEAD').writeAsStringSync(headBefore); // two behind
    final reopened = await Archive.open(tmp, clock: clock);
    expect((await reopened.verify()).count, 3);
  });

  test('a damaged HEAD is archive corruption, not a type error', () async {
    final archive = await Archive.open(tmp, clock: clock);
    await archive.append(draft());
    for (final bad in ['not json', '{"count":"3"}', '[]', '{"count":1.0}']) {
      File('${tmp.path}/HEAD').writeAsStringSync(bad);
      await expectLater(
        archive.append(draft()),
        throwsA(
          isA<ArchiveCorruptionError>().having(
            (e) => e.file,
            'file',
            endsWith('HEAD'),
          ),
        ),
      );
    }
  });

  test('invalid UTF-8 is corruption naming the file and line', () async {
    final archive = await Archive.open(tmp, clock: clock);
    await archive.append(draft());
    dayFile('2026-08-23')
        .writeAsBytesSync([0xff, 0xfe, 0x0a], mode: FileMode.append);
    await expectLater(
      archive.events().toList(),
      throwsA(
        isA<ArchiveCorruptionError>()
            .having((e) => e.file, 'file', endsWith('2026-08-23.jsonl'))
            .having((e) => e.reason, 'reason', contains('line 2')),
      ),
    );
  });

  test('close releases the lock handle; the archive keeps working', () async {
    final archive = await Archive.open(tmp, clock: clock);
    await archive.append(draft());
    await archive.close();
    await archive.append(draft());
    expect((await archive.verify()).count, 2);
  });

  test('stray files in events/ are ignored', () async {
    final archive = await Archive.open(tmp, clock: clock);
    await archive.append(draft());
    File('${tmp.path}/events/.DS_Store').writeAsStringSync('junk');
    expect(await archive.events().toList(), hasLength(1));
  });
}
