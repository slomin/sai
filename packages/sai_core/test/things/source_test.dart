import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sai_core/sai_core.dart';
import 'package:sai_core/things_testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_things_source_test');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String seed() {
    final path = p.join(tmp.path, 'main.sqlite');
    final f = ThingsFixture(path);
    final home = f.area('Home');
    final kitchen = f.project('Kitchen', area: home, start: 1);
    final oat = f.item('Buy oat milk', project: kitchen, start: 1);
    f.tagTask(oat, f.tag('errand'));
    f.checklist(oat, 'oat');
    f.close();
    return path;
  }

  group('readThingsSnapshot (#40)', () {
    test(
      'reads the same rows as a direct read, off the main isolate',
      () async {
        final path = seed();
        final direct = ThingsDatabase.snapshot(path);
        addTearDown(direct.dispose);
        final expected = direct.read();
        final actual = await readThingsSnapshot(path);
        expect(
          actual.areas.map((a) => a.uuid),
          expected.areas.map((a) => a.uuid),
        );
        expect(
          actual.tags.map((t) => t.uuid),
          expected.tags.map((t) => t.uuid),
        );
        expect(
          actual.items.map((i) => i.uuid),
          expected.items.map((i) => i.uuid),
        );
        expect(actual.taskTags, expected.taskTags);
        expect(
          actual.checklistItems.map((c) => c.uuid),
          expected.checklistItems.map((c) => c.uuid),
        );
      },
    );

    test('a foreign file is a ThingsSchemaException, a missing one a '
        'FileSystemException', () async {
      final foreign = File(p.join(tmp.path, 'x.sqlite'))
        ..writeAsStringSync('nope');
      expect(
        () => readThingsSnapshot(foreign.path),
        throwsA(isA<ThingsSchemaException>()),
      );
      expect(
        () => readThingsSnapshot(p.join(tmp.path, 'gone.sqlite')),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('ThingsFailure', () {
    test('every exception the importer throws has a name and a next step', () {
      final cases = <Object, Type>{
        ThingsAmbiguousDatabase(2): ThingsAmbiguous,
        ThingsSchemaException('missing table TMArea'): ThingsNotADatabase,
        ThingsSchemaException.inconsistent('torn'): ThingsTorn,
        const FileSystemException('denied', '/x/main.sqlite'): ThingsUnreadable,
        ThingsImportException(
          const CreateArea(uuid: 'area-001', title: 'Home', createdAt: null),
          StateError('refused'),
          appended: 4,
        ): ThingsStopped,
        StateError('anything else'): ThingsUnreadable,
      };
      for (final entry in cases.entries) {
        final failure = classifyThingsError(entry.key, path: '/x/main.sqlite');
        expect(failure.runtimeType, entry.value, reason: '${entry.key}');
        expect(failure.headline, isNotEmpty);
        expect(failure.nextAction, isNotEmpty);
        expect(failure.headline, isNot(contains('Home')));
        expect(failure.nextAction, isNot(contains('Home')));
      }
    });

    test('the specifics survive the mapping', () {
      final ambiguous =
          classifyThingsError(ThingsAmbiguousDatabase(3)) as ThingsAmbiguous;
      expect(ambiguous.count, 3);
      expect(ambiguous.headline, contains('3'));
      final stopped = classifyThingsError(
        ThingsImportException(
          const CreateArea(uuid: 'area-001', title: 'Home', createdAt: null),
          StateError('refused'),
          appended: 4,
        ),
      ) as ThingsStopped;
      expect(stopped.appended, 4);
      expect(stopped.nextAction, contains('again'));
      final unreadable = classifyThingsError(
        const FileSystemException('denied', '/x/main.sqlite'),
      ) as ThingsUnreadable;
      expect(unreadable.path, '/x/main.sqlite');
      expect(unreadable.nextAction, contains('Full Disk Access'));
      expect(const ThingsNotFound().nextAction, contains('choose'));
    });
  });

  group('unsupportedLabel', () {
    test('rewrites the buckets that name a command-line flag', () {
      for (final bucket in [
        Unsupported.openOnly,
        Unsupported.repeatHistory,
        Unsupported.logbookBefore(const CalendarDate(2026, 1, 1)),
      ]) {
        expect(unsupportedLabel(bucket), isNot(contains('--')));
        expect(unsupportedLabel(bucket), isNotEmpty);
      }
      expect(unsupportedLabel(Unsupported.trashed), Unsupported.trashed);
    });
  });

  group('importThings progress', () {
    test('reports every operation, ending at the total', () async {
      final path = seed();
      final archive = await Archive.open(Directory(p.join(tmp.path, 'a')));
      final store = await TaskStore.open(archive, source: 'sai/test');
      addTearDown(() async {
        store.dispose();
        await archive.close();
      });
      final db = ThingsDatabase.snapshot(path);
      addTearDown(db.dispose);
      final seen = <(int, int)>[];
      final result = await importThings(
        db.read(),
        store: store,
        now: DateTime.utc(2026, 8, 27),
        onProgress: (done, total) => seen.add((done, total)),
      );
      expect(seen, hasLength(result.plan.length));
      expect(seen.last, (result.plan.length, result.plan.length));
      expect(seen.map((s) => s.$1), List.generate(seen.length, (i) => i + 1));
    });
  });
}
