import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sai_core/sai_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'package:sai_core/things_testing.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_things_db_test');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('locateThingsDatabase', () {
    test('prefers the environment override', () {
      expect(
        locateThingsDatabase(
          environment: {thingsDatabaseEnv: '/x/main.sqlite'},
          home: tmp.path,
        ),
        '/x/main.sqlite',
      );
    });

    test('finds the first ThingsData-* database under the container', () {
      for (final data in ['ThingsData-ZZZZZ', 'ThingsData-AAAAA']) {
        final dir = Directory(
          p.join(
            tmp.path,
            thingsContainerRelative,
            data,
            'Things Database.thingsdatabase',
          ),
        )..createSync(recursive: true);
        File(p.join(dir.path, 'main.sqlite')).writeAsStringSync('');
      }
      Directory(p.join(tmp.path, thingsContainerRelative, 'ThingsData-EMPTY'))
          .createSync();
      expect(
        locateThingsDatabase(environment: const {}, home: tmp.path),
        p.join(
          tmp.path,
          thingsContainerRelative,
          'ThingsData-AAAAA',
          'Things Database.thingsdatabase',
          'main.sqlite',
        ),
      );
    });

    test('is null without a container or with an empty override', () {
      expect(
        locateThingsDatabase(
          environment: {thingsDatabaseEnv: ''},
          home: tmp.path,
        ),
        isNull,
      );
    });
  });

  group('ThingsDatabase.snapshot', () {
    test(
      'reads rows that live only in the WAL and leaves the source alone',
      () {
        final path = p.join(tmp.path, 'main.sqlite');
        final fixture = ThingsFixture(path);
        fixture.area('Home');
        fixture.item('Buy oat milk');
        // The writer stays open, so the rows sit in the WAL — the state a
        // running Things leaves behind.
        addTearDown(fixture.close);
        expect(File('$path-wal').lengthSync(), greaterThan(0));
        final before = {
          for (final f in tmp.listSync().whereType<File>())
            p.basename(f.path): f.lastModifiedSync(),
        };

        final db = ThingsDatabase.snapshot(path);
        final snapshot = db.read();
        expect(snapshot.areas.single.title, 'Home');
        expect(snapshot.items.single.title, 'Buy oat milk');
        expect(db.sourcePath, path);

        final after = {
          for (final f in tmp.listSync().whereType<File>())
            p.basename(f.path): f.lastModifiedSync(),
        };
        expect(after, before);
        db.dispose();
      },
    );

    test('copies into a private directory that dispose removes', () {
      final path = p.join(tmp.path, 'main.sqlite');
      ThingsFixture(path).close();
      final db = ThingsDatabase.snapshot(path);
      final copy = db.copyDirectory;
      expect(copy.existsSync(), isTrue);
      expect(p.basename(copy.path), startsWith('sai_things_copy_'));
      expect(p.isWithin(Directory.systemTemp.path, copy.path), isTrue);
      db.dispose();
      expect(copy.existsSync(), isFalse);
    });

    test('refuses a database without the Things tables', () {
      final path = p.join(tmp.path, 'other.sqlite');
      sqlite3.open(path)
        ..execute('create table t (x)')
        ..close();
      expect(
        () => ThingsDatabase.snapshot(path),
        throwsA(
          isA<ThingsSchemaException>().having(
            (e) => e.message,
            'message',
            'missing table TMArea',
          ),
        ),
      );
    });

    test('refuses a table missing a column the reader uses', () {
      final path = p.join(tmp.path, 'old.sqlite');
      sqlite3.open(path)
        ..execute(
          thingsFixtureDdl.replaceFirst('"rt1_repeatingTemplate" TEXT,', ''),
        )
        ..close();
      expect(
        () => ThingsDatabase.snapshot(path),
        throwsA(
          isA<ThingsSchemaException>().having(
            (e) => e.message,
            'message',
            'missing column TMTask.rt1_repeatingTemplate',
          ),
        ),
      );
    });

    test('a torn copy is retried and then refused, never trusted', () {
      final path = p.join(tmp.path, 'torn.sqlite');
      final f = ThingsFixture(path);
      for (var i = 0; i < 40; i++) {
        f.item('row ' * 50);
      }
      f.close();
      // Damage every page after the first: the header still reads as
      // SQLite and the file opens, quick_check does not pass.
      final file = File(path);
      final bytes = file.readAsBytesSync();
      for (var i = 4096; i < bytes.length; i++) {
        bytes[i] = 0xFF;
      }
      file.writeAsBytesSync(bytes);
      expect(
        () => ThingsDatabase.snapshot(path),
        throwsA(
          isA<ThingsSchemaException>().having(
            (e) => e.message,
            'message',
            startsWith(
              'no consistent snapshot after '
              '${ThingsDatabase.snapshotAttempts} attempts',
            ),
          ),
        ),
      );
    });

    test('a missing file is a FileSystemException', () {
      expect(
        () => ThingsDatabase.snapshot(p.join(tmp.path, 'nope.sqlite')),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('ThingsDatabase.read', () {
    test('decodes enums, links and companions', () {
      final path = p.join(tmp.path, 'main.sqlite');
      final f = ThingsFixture(path);
      final area = f.area('Home', visible: false);
      final tag = f.tag('errand', shortcut: 'e');
      final child = f.tag('urgent', parent: tag);
      final project = f.project('Kitchen', area: area, start: 1);
      final heading = f.heading('Shopping', project: project);
      final task = f.item(
        'Buy oat milk',
        start: 1,
        startDate: const CalendarDate(2026, 8, 24),
        deadline: const CalendarDate(2026, 8, 30),
        heading: heading,
        project: project,
        status: 3,
        stopped: DateTime.utc(2026, 8, 25, 10),
        reminderTime: 5,
      );
      final template = f.item('Water plants', template: true, start: 1);
      final instance = f.item(
        'Water plants',
        start: 1,
        repeatingTemplate: template,
      );
      final trashed = f.item('Old', trashed: true, status: 2);
      f.checklist(task, 'oat', status: 3, stopped: DateTime.utc(2026, 8, 25));
      f.checklist(task, 'milk');
      f.tagTask(task, tag);
      f.tagTask(task, child);
      f.tagArea(area, tag);
      f.close();

      final db = ThingsDatabase.snapshot(path);
      addTearDown(db.dispose);
      final s = db.read();

      expect(s.areas.single.visible, isFalse);
      expect(s.tags.map((t) => (t.title, t.parent, t.shortcut)), [
        ('errand', null, 'e'),
        ('urgent', tag, null),
      ]);
      final byId = {for (final i in s.items) i.uuid: i};
      expect(byId[project]!.type, ThingsItemType.project);
      expect(byId[project]!.area, area);
      expect(byId[heading]!.type, ThingsItemType.heading);
      final t = byId[task]!;
      expect(t.type, ThingsItemType.task);
      expect(t.status, ThingsStatus.completed);
      expect(t.start, ThingsStart.anytime);
      expect(decodeThingsDay(t.startDate), const CalendarDate(2026, 8, 24));
      expect(decodeThingsDay(t.deadline), const CalendarDate(2026, 8, 30));
      expect(t.heading, heading);
      expect(decodeThingsInstant(t.stopDate), DateTime.utc(2026, 8, 25, 10));
      expect(t.reminderTime, 5);
      expect(byId[template]!.isRepeatingTemplate, isTrue);
      expect(byId[instance]!.repeatingTemplate, template);
      expect(byId[instance]!.isRepeatingTemplate, isFalse);
      expect(byId[trashed]!.trashed, isTrue);
      expect(byId[trashed]!.status, ThingsStatus.cancelled);
      expect(s.checklistItems.map((c) => (c.title, c.status)), [
        ('oat', ThingsStatus.completed),
        ('milk', ThingsStatus.open),
      ]);
      expect(s.taskTags, {
        task: [tag, child],
      });
      expect(s.areaTags, {
        area: [tag],
      });
    });
  });
}
