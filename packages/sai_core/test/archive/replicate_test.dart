import 'dart:convert';
import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Directory root;
  late Directory replica;

  var nowMicros = DateTime.utc(2026, 8, 23, 10).microsecondsSinceEpoch;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_replicate_test');
    root = Directory('${tmp.path}/archive');
    replica = Directory('${tmp.path}/replica');
    nowMicros = DateTime.utc(2026, 8, 23, 10).microsecondsSinceEpoch;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  DateTime clock() {
    nowMicros += 1000;
    return DateTime.fromMicrosecondsSinceEpoch(nowMicros, isUtc: true);
  }

  EventDraft draft([String text = 'hello', DateTime? ts]) => EventDraft(
    type: EventTypes.chatMessage,
    actor: Actor.user,
    source: 'sai/tui',
    payload: {'text': text},
    ts: ts,
  );

  File day(Directory at, String day) => File('${at.path}/events/$day.jsonl');
  String head(Directory at) => File('${at.path}/HEAD').readAsStringSync();
  String manifest(Directory at) =>
      File('${at.path}/MANIFEST.json').readAsStringSync();

  /// Three days, five events.
  Future<Archive> seed() async {
    final archive = await Archive.open(root, clock: clock);
    await archive.append(draft('#0', DateTime.utc(2026, 8, 23, 10)));
    await archive.append(draft('#1', DateTime.utc(2026, 8, 23, 11)));
    await archive.append(draft('#2', DateTime.utc(2026, 8, 24, 10)));
    await archive.append(draft('#3', DateTime.utc(2026, 8, 25, 10)));
    await archive.append(draft('#4', DateTime.utc(2026, 8, 25, 11)));
    nowMicros = DateTime.utc(2026, 8, 25, 12).microsecondsSinceEpoch;
    return archive;
  }

  group('replicateTo (#15)', () {
    test('the first replication copies everything and verifies', () async {
      final archive = await seed();
      final report = await archive.replicateTo(replica);
      expect(report.count, 5);
      expect(report.head, (await archive.head()).head);
      expect(report.filesCopied, 3);
      expect(
        report.bytesCopied,
        File('${root.path}/MANIFEST.json').lengthSync() +
            day(root, '2026-08-23').lengthSync() +
            day(root, '2026-08-24').lengthSync() +
            day(root, '2026-08-25').lengthSync(),
      );
      expect(manifest(replica), manifest(root));
      expect(head(replica), head(root));
      for (final d in ['2026-08-23', '2026-08-24', '2026-08-25']) {
        expect(
          day(replica, d).readAsBytesSync(),
          day(root, d).readAsBytesSync(),
        );
      }
      expect(File('${replica.path}/LOCK').existsSync(), isTrue);
      final check = await Archive.open(replica, clock: clock);
      expect((await check.verify()).count, 5);
      await check.close();
    });

    test('a second run copies only the day file that grew', () async {
      final archive = await seed();
      await archive.replicateTo(replica);
      final untouched = day(replica, '2026-08-23').lastModifiedSync();
      final middle = day(replica, '2026-08-24').lastModifiedSync();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await archive.append(draft('#5', DateTime.utc(2026, 8, 25, 12)));
      final report = await archive.replicateTo(replica);
      expect(report.count, 6);
      expect(report.filesCopied, 1);
      expect(report.bytesCopied, day(root, '2026-08-25').lengthSync());
      expect(day(replica, '2026-08-23').lastModifiedSync(), untouched);
      expect(day(replica, '2026-08-24').lastModifiedSync(), middle);
      expect(head(replica), head(root));
      expect(
        day(replica, '2026-08-25').readAsBytesSync(),
        day(root, '2026-08-25').readAsBytesSync(),
      );
    });

    test('nothing to copy is still a verified report', () async {
      final archive = await seed();
      await archive.replicateTo(replica);
      final report = await archive.replicateTo(replica);
      expect(report.count, 5);
      expect(report.filesCopied, 0);
      expect(report.bytesCopied, 0);
    });

    test('a replica ahead of the source is refused, nothing written', () async {
      final archive = await seed();
      await archive.replicateTo(replica);
      final before = head(replica);
      day(
        replica,
        '2026-08-25',
      ).writeAsStringSync('{"more":true}\n', mode: FileMode.append);
      await expectLater(
        archive.replicateTo(replica),
        throwsA(
          isA<ReplicaRefusedError>().having(
            (e) => e.reason,
            'reason',
            contains('diverged'),
          ),
        ),
      );
      expect(head(replica), before);
    });

    test('a replica day the source lacks is refused', () async {
      final archive = await seed();
      await archive.replicateTo(replica);
      day(replica, '2026-08-26').writeAsStringSync('{"other":true}\n');
      await expectLater(
        archive.replicateTo(replica),
        throwsA(
          isA<ReplicaRefusedError>().having(
            (e) => e.reason,
            'reason',
            allOf(contains('diverged'), contains('2026-08-26.jsonl')),
          ),
        ),
      );
    });

    test(
      'a same-length newest day with another last line is refused',
      () async {
        final archive = await seed();
        await archive.replicateTo(replica);
        final file = day(replica, '2026-08-25');
        file.writeAsStringSync(
          file.readAsStringSync().replaceFirst('#4', '#9'),
        );
        await expectLater(
          archive.replicateTo(replica),
          throwsA(
            isA<ReplicaRefusedError>().having(
              (e) => e.reason,
              'reason',
              contains('diverged'),
            ),
          ),
        );
      },
    );

    test("another archive's replica is refused", () async {
      final archive = await seed();
      final other = await Archive.open(replica, clock: clock);
      await other.append(draft('elsewhere'));
      await other.close();
      final before = head(replica);
      await expectLater(
        archive.replicateTo(replica),
        throwsA(
          isA<ReplicaRefusedError>().having(
            (e) => e.reason,
            'reason',
            contains('another archive'),
          ),
        ),
      );
      expect(head(replica), before);
    });

    test('day files with no manifest are refused', () async {
      final archive = await seed();
      Directory('${replica.path}/events').createSync(recursive: true);
      day(replica, '2026-08-23').writeAsStringSync('{"x":1}\n');
      await expectLater(
        archive.replicateTo(replica),
        throwsA(isA<ReplicaRefusedError>()),
      );
      expect(File('${replica.path}/HEAD').existsSync(), isFalse);
    });

    test('the archive itself, inside it, or above it is refused', () async {
      final archive = await seed();
      for (final bad in [
        root,
        Directory('${root.path}/'),
        Directory('${root.path}/events/replica'),
        tmp,
        Directory('${root.path}/../archive'),
      ]) {
        await expectLater(
          archive.replicateTo(bad),
          throwsA(isA<ReplicaRefusedError>()),
          reason: bad.path,
        );
      }
      expect(Directory('${root.path}/events/replica').existsSync(), isFalse);
    });

    test('a symlink to the archive is the archive', () async {
      final archive = await seed();
      final link = Link('${tmp.path}/link')..createSync(root.path);
      await expectLater(
        archive.replicateTo(Directory(link.path)),
        throwsA(isA<ReplicaRefusedError>()),
      );
    });

    test(
      'an unmounted destination is unavailable and nothing is created',
      () async {
        final archive = await seed();
        final gone = Directory('${tmp.path}/Volumes/Backup/sai');
        await expectLater(
          archive.replicateTo(gone),
          throwsA(
            isA<ReplicaUnavailableError>().having(
              (e) => e.reason,
              'reason',
              contains('not mounted'),
            ),
          ),
        );
        expect(Directory('${tmp.path}/Volumes').existsSync(), isFalse);
      },
    );

    test('a leftover temp file is removed and never counted', () async {
      final archive = await seed();
      await archive.replicateTo(replica);
      final tmpFile = File('${replica.path}/events/2026-08-25.jsonl.tmp')
        ..writeAsStringSync('half');
      final report = await archive.replicateTo(replica);
      expect(report.filesCopied, 0);
      expect(tmpFile.existsSync(), isFalse);
    });

    test(
      'a zero-length replica day is neither a divergence nor kept',
      () async {
        final archive = await seed();
        Directory('${replica.path}/events').createSync(recursive: true);
        File('${replica.path}/MANIFEST.json').writeAsStringSync(manifest(root));
        day(replica, '2026-08-24').writeAsStringSync('');
        day(replica, '2026-08-30').writeAsStringSync('');
        final report = await archive.replicateTo(replica);
        expect(report.count, 5);
        expect(report.filesCopied, 3);
        expect(
          day(replica, '2026-08-24').readAsBytesSync(),
          day(root, '2026-08-24').readAsBytesSync(),
        );
      },
    );

    test(
      'a racing writer never leaves a replica that fails to verify',
      () async {
        final archive = await seed();
        final writer = await Archive.open(root, clock: clock);
        final results = await Future.wait<Object>([
          archive.replicateTo(replica),
          for (var i = 0; i < 20; i++)
            writer.append(draft('race#$i', DateTime.utc(2026, 8, 25, 12, i))),
        ]);
        final report = results.first as ReplicaReport;
        expect(report.count, inInclusiveRange(5, 25));
        final check = await Archive.open(replica, clock: clock);
        expect((await check.verify()).count, report.count);
        await check.close();
        await writer.close();
        expect((await archive.replicateTo(replica)).count, 25);
      },
    );

    test(
      'two replications to one replica, from two instances, serialize',
      () async {
        final archive = await seed();
        final other = await Archive.open(root, clock: clock);
        final reports = await Future.wait([
          archive.replicateTo(replica),
          other.replicateTo(replica),
          archive.replicateTo(replica),
        ]);
        expect(reports.map((r) => r.count), everyElement(5));
        expect(reports.map((r) => r.filesCopied).reduce((a, b) => a + b), 3);
        await other.close();
      },
    );

    test('opening the replica afterwards rewrites nothing', () async {
      final archive = await seed();
      await archive.replicateTo(replica);
      final before = head(replica);
      final check = await Archive.open(replica, clock: clock);
      await check.close();
      expect(head(replica), before);
    });

    test('a torn source tail is reported, not replicated over', () async {
      final archive = await seed();
      day(
        root,
        '2026-08-25',
      ).writeAsStringSync('{"torn', mode: FileMode.append);
      await expectLater(
        archive.replicateTo(replica),
        throwsA(isA<TornTailError>()),
      );
    });

    test('a corrupted source line is reported by file and line', () async {
      final archive = await seed();
      final file = day(root, '2026-08-24');
      file.writeAsStringSync(file.readAsStringSync().replaceFirst('#2', '#x'));
      await expectLater(
        archive.replicateTo(replica),
        throwsA(
          isA<ArchiveCorruptionError>().having(
            (e) => e.file,
            'file',
            endsWith('2026-08-25.jsonl'),
          ),
        ),
      );
    });

    test('the report says what a copy cost, and HEAD is byte-equal', () async {
      final archive = await seed();
      final report = await archive.replicateTo(replica);
      expect('$report', contains('5'));
      expect(jsonDecode(head(replica)), jsonDecode(head(root)));
    });
  });

  group('restore (#15)', () {
    late Directory fresh;
    setUp(() => fresh = Directory('${tmp.path}/restored'));

    Future<void> replicate() async {
      final archive = await seed();
      await archive.replicateTo(replica);
      await archive.close();
    }

    test('into an absent root: every byte back, every hash checked', () async {
      await replicate();
      final report = await Archive.restore(from: replica, into: fresh);
      expect(report.count, 5);
      expect(
        report.head,
        BlobRef.parse((jsonDecode(head(replica)) as Map)['head'] as String),
      );
      expect(manifest(fresh), manifest(replica));
      for (final d in ['2026-08-23', '2026-08-24', '2026-08-25']) {
        expect(
          day(fresh, d).readAsBytesSync(),
          day(replica, d).readAsBytesSync(),
        );
      }
      final restored = jsonDecode(head(fresh)) as Map<String, Object?>;
      final original = jsonDecode(head(replica)) as Map<String, Object?>;
      expect(restored['count'], original['count']);
      expect(restored['head'], original['head']);
      final live = await Archive.open(fresh, clock: clock);
      await live.append(draft('after the restore'));
      expect((await live.verify()).count, 6);
      await live.close();
    });

    test('into an empty root a client already opened', () async {
      await replicate();
      final empty = await Archive.open(fresh, clock: clock);
      await empty.close();
      expect(manifest(fresh), isNot(manifest(replica)));
      final report = await Archive.restore(from: replica, into: fresh);
      expect(report.count, 5);
      expect(manifest(fresh), manifest(replica));
    });

    test('refused into a root that holds events, untouched', () async {
      await replicate();
      final busy = await Archive.open(fresh, clock: clock);
      await busy.append(draft('mine'));
      await busy.close();
      final before = head(fresh);
      await expectLater(
        Archive.restore(from: replica, into: fresh),
        throwsA(
          isA<ReplicaRefusedError>().having(
            (e) => e.reason,
            'reason',
            contains('not empty'),
          ),
        ),
      );
      expect(head(fresh), before);
      expect(day(fresh, '2026-08-24').existsSync(), isFalse);
    });

    test(
      'refused from a replica that fails its own walk, nothing created',
      () async {
        await replicate();
        final file = day(replica, '2026-08-24');
        file.writeAsStringSync(
          file.readAsStringSync().replaceFirst('#2', '#x'),
        );
        await expectLater(
          Archive.restore(from: replica, into: fresh),
          throwsA(isA<ArchiveCorruptionError>()),
        );
        expect(fresh.existsSync(), isFalse);
      },
    );

    test('a torn replica tail is reported, not restored', () async {
      await replicate();
      day(
        replica,
        '2026-08-25',
      ).writeAsStringSync('{"torn', mode: FileMode.append);
      await expectLater(
        Archive.restore(from: replica, into: fresh),
        throwsA(isA<TornTailError>()),
      );
      expect(fresh.existsSync(), isFalse);
    });

    test('the replica is read, never opened: no LOCK, no rewrite', () async {
      await replicate();
      File('${replica.path}/LOCK').deleteSync();
      final headBefore = head(replica);
      await Archive.restore(from: replica, into: fresh);
      expect(File('${replica.path}/LOCK').existsSync(), isFalse);
      expect(head(replica), headBefore);
    });

    test(
      'a replica whose HEAD is one behind a truthful tail restores',
      () async {
        final archive = await seed();
        await archive.replicateTo(replica);
        final stale = head(replica);
        await archive.append(draft('#5', DateTime.utc(2026, 8, 25, 12)));
        await archive.replicateTo(replica);
        await archive.close();
        File('${replica.path}/HEAD').writeAsStringSync(stale);
        final report = await Archive.restore(from: replica, into: fresh);
        expect(report.count, 6);
        expect((jsonDecode(head(fresh)) as Map)['count'], 6);
      },
    );

    test('a directory that is not a replica is refused', () async {
      replica.createSync();
      await expectLater(
        Archive.restore(from: replica, into: fresh),
        throwsA(
          isA<ReplicaRefusedError>().having(
            (e) => e.reason,
            'reason',
            contains('not an archive'),
          ),
        ),
      );
      Directory('${replica.path}/events').createSync();
      File('${replica.path}/MANIFEST.json').writeAsStringSync('{}\n');
      await expectLater(
        Archive.restore(from: replica, into: fresh),
        throwsA(isA<ReplicaRefusedError>()),
      );
      expect(fresh.existsSync(), isFalse);
    });

    test('overlapping roots are refused', () async {
      await replicate();
      await expectLater(
        Archive.restore(from: replica, into: replica),
        throwsA(isA<ReplicaRefusedError>()),
      );
      await expectLater(
        Archive.restore(from: replica, into: Directory('${replica.path}/x')),
        throwsA(isA<ReplicaRefusedError>()),
      );
      await expectLater(
        Archive.restore(from: replica, into: tmp),
        throwsA(isA<ReplicaRefusedError>()),
      );
    });
  });
}
