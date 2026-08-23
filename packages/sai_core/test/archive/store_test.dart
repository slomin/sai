import 'dart:convert';
import 'dart:io';

import 'package:sai_core/src/archive/store.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late ArchiveStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_store_test');
    store = ArchiveStore(tmp);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('ensureLayout creates the manifest, head, lock and events dir once', () {
    store.ensureLayout(createdTs: '2026-08-23T00:00:00.000000Z');
    expect(store.eventsDir.existsSync(), isTrue);
    expect(store.lockFile.existsSync(), isTrue);
    final manifest = jsonDecode(
      store.manifestFile.readAsStringSync(),
    ) as Map<String, Object?>;
    expect(manifest['format'], 'sai-event-log');
    expect(manifest['version'], 0);
    expect(manifest['created'], '2026-08-23T00:00:00.000000Z');
    final head = store.readHead();
    expect(head.count, 0);
    expect(head.head, isNull);

    // A second call must not reset anything.
    store.writeHead(
      HeadRecord(count: 3, head: null, updated: '2026-08-23T01:00:00.000000Z'),
    );
    store.ensureLayout(createdTs: '2027-01-01T00:00:00.000000Z');
    expect(
      (jsonDecode(store.manifestFile.readAsStringSync())
          as Map<String, Object?>)['created'],
      '2026-08-23T00:00:00.000000Z',
    );
    expect(store.readHead().count, 3);
  });

  test('HEAD round-trips and leaves no temp file behind', () {
    store.ensureLayout(createdTs: '2026-08-23T00:00:00.000000Z');
    final ref = BlobRef.sha256OfBytes(utf8.encode('x'));
    store.writeHead(
      HeadRecord(count: 7, head: ref, updated: '2026-08-23T02:00:00.000000Z'),
    );
    final head = store.readHead();
    expect(head.count, 7);
    expect(head.head, ref);
    expect(head.updated, '2026-08-23T02:00:00.000000Z');
    expect(
      tmp.listSync().map((e) => e.uri.pathSegments.last),
      isNot(contains('HEAD.tmp')),
    );
  });

  test('appendLine writes newline-terminated lines in order', () {
    store.ensureLayout(createdTs: '2026-08-23T00:00:00.000000Z');
    final day = store.dayFile('2026-08-23');
    store.appendLine(day, utf8.encode('{"a":1}'));
    store.appendLine(day, utf8.encode('{"b":2}'));
    expect(day.readAsStringSync(), '{"a":1}\n{"b":2}\n');
    final (lines, torn) = store.readDayLines(day);
    expect(lines, ['{"a":1}', '{"b":2}']);
    expect(torn, isNull);
  });

  group('readDayLines torn-tail classification', () {
    test('clean and empty files are not torn', () {
      store.ensureLayout(createdTs: '2026-08-23T00:00:00.000000Z');
      final day = store.dayFile('2026-08-23');
      day.writeAsStringSync('');
      final (lines, torn) = store.readDayLines(day);
      expect(lines, isEmpty);
      expect(torn, isNull);
    });

    test('bytes after the last newline are a torn tail at their offset', () {
      store.ensureLayout(createdTs: '2026-08-23T00:00:00.000000Z');
      final day = store.dayFile('2026-08-23');
      day.writeAsStringSync('{"a":1}\n{"b"');
      final (lines, torn) = store.readDayLines(day);
      expect(lines, ['{"a":1}']);
      expect(torn, 8);
    });

    test('a file with no newline at all is torn at offset zero', () {
      store.ensureLayout(createdTs: '2026-08-23T00:00:00.000000Z');
      final day = store.dayFile('2026-08-23');
      day.writeAsStringSync('{"a"');
      final (lines, torn) = store.readDayLines(day);
      expect(lines, isEmpty);
      expect(torn, 0);
    });
  });

  test('dayFiles lists only day-named files, sorted', () {
    store.ensureLayout(createdTs: '2026-08-23T00:00:00.000000Z');
    store.dayFile('2026-08-24').writeAsStringSync('{}\n');
    store.dayFile('2026-08-22').writeAsStringSync('{}\n');
    store.dayFile('2026-08-23').writeAsStringSync('{}\n');
    File('${store.eventsDir.path}/.DS_Store').writeAsStringSync('junk');
    File('${store.eventsDir.path}/notes.txt').writeAsStringSync('junk');
    expect(store.dayFiles().map((f) => f.uri.pathSegments.last).toList(), [
      '2026-08-22.jsonl',
      '2026-08-23.jsonl',
      '2026-08-24.jsonl',
    ]);
  });

  test('withLock serializes concurrent actions on the same root', () async {
    store.ensureLayout(createdTs: '2026-08-23T00:00:00.000000Z');
    final other = ArchiveStore(tmp); // a second instance, same root
    var inside = 0;
    final order = <int>[];
    Future<void> critical(int who) async {
      inside++;
      expect(inside, 1, reason: 'two actions overlapped');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      order.add(who);
      inside--;
    }

    await Future.wait([
      store.withLock(() => critical(1)),
      other.withLock(() => critical(2)),
      store.withLock(() => critical(3)),
    ]);
    expect(order, hasLength(3));
  });
}
