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

  test('an event in the wrong day file is corruption', () async {
    final archive = await Archive.open(tmp, clock: clock);
    await archive.append(draft());
    dayFile('2026-08-23').renameSync(dayFile('2026-08-24').path);
    await expectLater(
      archive.events().toList(),
      throwsA(
        isA<ArchiveCorruptionError>().having(
          (e) => e.reason,
          'reason',
          contains('day'),
        ),
      ),
    );
  });

  test('a draft timestamped before the newest day file is refused', () async {
    final archive = await Archive.open(tmp, clock: clock);
    await archive.append(draft());
    final stale = EventDraft(
      type: EventTypes.chatMessage,
      actor: Actor.user,
      source: 'sai/tui',
      payload: {'text': 'yesterday'},
      ts: DateTime.utc(2026, 8, 22, 12),
    );
    await expectLater(archive.append(stale), throwsArgumentError);
  });

  test('an empty day file is corruption', () async {
    final archive = await Archive.open(tmp, clock: clock);
    await archive.append(draft());
    dayFile('2026-08-22').writeAsStringSync('');
    await expectLater(
      archive.events().toList(),
      throwsA(isA<ArchiveCorruptionError>()),
    );
  });

  test('stray files in events/ are ignored', () async {
    final archive = await Archive.open(tmp, clock: clock);
    await archive.append(draft());
    File('${tmp.path}/events/.DS_Store').writeAsStringSync('junk');
    expect(await archive.events().toList(), hasLength(1));
  });
}
