import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  final id = BlobRef.sha256OfBytes([1]);
  final otherId = BlobRef.sha256OfBytes([2]);
  final created = DateTime.utc(2026, 8, 20, 10, 30, 0, 0, 1);
  final modified = DateTime.utc(2026, 8, 24, 9, 15);

  Task fullTask() => Task(
    id: id,
    title: 'Buy milk',
    notes: 'oat, not dairy',
    when: TaskWhen.date(const CalendarDate(2026, 8, 24)),
    deadline: const CalendarDate(2026, 8, 30),
    project: otherId,
    heading: BlobRef.sha256OfBytes([3]),
    tags: [
      BlobRef.sha256OfBytes([4]),
    ],
    checklist: [
      ChecklistItem(title: 'oat', completedAt: DateTime.utc(2026, 8, 21)),
      const ChecklistItem(title: 'soy'),
    ],
    createdAt: created,
    modifiedAt: modified,
    completedAt: DateTime.utc(2026, 8, 24, 12),
    external: const ExternalRef(
      system: 'things3',
      id: 'ABC-123',
      version: '3.22',
      instance: '2026-08-24',
    ),
  );

  Task bareTask() =>
      Task(id: id, title: 'x', createdAt: created, modifiedAt: created);

  group('TaskWhen', () {
    test('encodes as null, "someday" or a date', () {
      expect(TaskWhen.none.toJson(), isNull);
      expect(TaskWhen.someday.toJson(), 'someday');
      expect(
        TaskWhen.date(const CalendarDate(2026, 8, 24)).toJson(),
        '2026-08-24',
      );
    });

    test('decodes each form and round-trips', () {
      for (final when in [
        TaskWhen.none,
        TaskWhen.someday,
        TaskWhen.date(const CalendarDate(2026, 8, 24)),
      ]) {
        expect(TaskWhen.fromJson(when.toJson()), when);
      }
    });

    test('rejects anything else', () {
      for (final json in ['tomorrow', '', 'SOMEDAY', 42, true, <String>[]]) {
        expect(
          () => TaskWhen.fromJson(json),
          throwsFormatException,
          reason: '$json',
        );
      }
    });

    test('none and someday are value-equal singletons', () {
      expect(TaskWhen.none, TaskWhen.none);
      expect(TaskWhen.someday, isNot(TaskWhen.none));
      expect(
        TaskWhen.date(const CalendarDate(2026, 8, 24)),
        TaskWhen.date(const CalendarDate(2026, 8, 24)),
      );
    });
  });

  group('JSON round-trips', () {
    test('Task, fully populated', () {
      final task = fullTask();
      expect(Task.fromJson(task.toJson()), task);
    });

    test('Task, minimal', () {
      final task = bareTask();
      final back = Task.fromJson(task.toJson());
      expect(back, task);
      expect(back.notes, '');
      expect(back.when, TaskWhen.none);
      expect(back.deadline, isNull);
      expect(back.project, isNull);
      expect(back.completedAt, isNull);
      expect(back.external, isNull);
    });

    test('Project, Heading, Area, Tag, ChecklistItem, ExternalRef', () {
      final project = Project(
        id: id,
        title: 'Kitchen',
        notes: 'refit',
        area: otherId,
        when: TaskWhen.someday,
        deadline: const CalendarDate(2027, 1, 1),
        tags: [
          BlobRef.sha256OfBytes([4]),
        ],
        createdAt: created,
        modifiedAt: modified,
        deletedAt: DateTime.utc(2026, 8, 25),
        archivedAt: DateTime.utc(2026, 8, 26),
        external: const ExternalRef(system: 'things3', id: 'P-1'),
      );
      expect(Project.fromJson(project.toJson()), project);
      expect(project.toJson()['archived_at'], '2026-08-26T00:00:00.000000Z');
      expect(
        project.copyWith(archivedAt: const Patch(null)).archivedAt,
        isNull,
      );

      final bareProject = Project(
        id: id,
        title: 'K',
        createdAt: created,
        modifiedAt: created,
      );
      expect(Project.fromJson(bareProject.toJson()), bareProject);

      final heading = Heading(
        id: id,
        project: otherId,
        title: 'Demolition',
        createdAt: created,
        modifiedAt: modified,
      );
      expect(Heading.fromJson(heading.toJson()), heading);

      final area = Area(
        id: id,
        title: 'Home',
        createdAt: created,
        modifiedAt: modified,
        external: const ExternalRef(system: 'things3', id: 'A-1'),
      );
      expect(Area.fromJson(area.toJson()), area);

      final tag = Tag(
        id: id,
        title: 'errand',
        parent: otherId,
        createdAt: created,
        modifiedAt: modified,
      );
      expect(Tag.fromJson(tag.toJson()), tag);

      final item = ChecklistItem(
        title: 'oat',
        completedAt: DateTime.utc(2026, 8, 21),
      );
      expect(ChecklistItem.fromJson(item.toJson()), item);
      expect(
        ChecklistItem.fromJson(const ChecklistItem(title: 'soy').toJson()),
        const ChecklistItem(title: 'soy'),
      );

      const external = ExternalRef(system: 'things3', id: 'T-9');
      expect(ExternalRef.fromJson(external.toJson()), external);
    });
  });

  group('strict decode', () {
    test('rejects unknown keys', () {
      final json = bareTask().toJson()..['color'] = 'red';
      expect(() => Task.fromJson(json), throwsFormatException);
      expect(
        () => ChecklistItem.fromJson({'title': 'x', 'done': true}),
        throwsFormatException,
      );
      expect(
        () => ExternalRef.fromJson({'system': 's', 'id': 'i', 'extra': 1}),
        throwsFormatException,
      );
    });

    test('rejects missing or empty required fields', () {
      expect(() => Task.fromJson({'id': id.toString()}), throwsFormatException);
      final noTitle = bareTask().toJson()..remove('title');
      expect(() => Task.fromJson(noTitle), throwsFormatException);
      final emptyTitle = bareTask().toJson()..['title'] = '';
      expect(() => Task.fromJson(emptyTitle), throwsFormatException);
      expect(
        () => ExternalRef.fromJson({'system': '', 'id': 'x'}),
        throwsFormatException,
      );
    });

    test('rejects wrong JSON types', () {
      final badTags = fullTask().toJson()..['tags'] = 'errand';
      expect(() => Task.fromJson(badTags), throwsFormatException);
      final badId = bareTask().toJson()..['id'] = 7;
      expect(() => Task.fromJson(badId), throwsFormatException);
      final badInstant = bareTask().toJson()..['created_at'] = '2026-08-20';
      expect(() => Task.fromJson(badInstant), throwsFormatException);
    });

    test('rejects present null optional strings', () {
      final nullNotes = bareTask().toJson()..['notes'] = null;
      expect(() => Task.fromJson(nullNotes), throwsFormatException);
      expect(
        () => ExternalRef.fromJson({
          'system': 'things3',
          'id': 'T-1',
          'version': null,
        }),
        throwsFormatException,
      );
    });
  });

  group('derived status', () {
    test('open when no lifecycle timestamp is set', () {
      expect(bareTask().status, TaskStatus.open);
    });

    test('completed and cancelled from their timestamps', () {
      expect(
        bareTask().copyWith(completedAt: Patch(created)).status,
        TaskStatus.completed,
      );
      expect(
        bareTask().copyWith(cancelledAt: Patch(created)).status,
        TaskStatus.cancelled,
      );
    });

    test('cancelled beats completed if both are somehow set', () {
      final task = bareTask().copyWith(
        completedAt: Patch(created),
        cancelledAt: Patch(modified),
      );
      expect(task.status, TaskStatus.cancelled);
    });
  });

  group('copyWith patch semantics', () {
    test('absent leaves the value, Patch(null) clears, Patch(v) sets', () {
      final task = fullTask();
      expect(task.copyWith().deadline, task.deadline);
      expect(task.copyWith(deadline: const Patch(null)).deadline, isNull);
      expect(
        task.copyWith(deadline: const Patch(CalendarDate(2026, 9, 1))).deadline,
        const CalendarDate(2026, 9, 1),
      );
      expect(
        task.copyWith(title: const Patch('Buy oat milk')).title,
        'Buy oat milk',
      );
      expect(task.copyWith(notes: const Patch('')).notes, '');
      final cleared = task.copyWith(
        project: const Patch(null),
        heading: const Patch(null),
      );
      expect(cleared.project, isNull);
      expect(cleared.heading, isNull);
      expect(cleared.title, task.title);
    });
  });

  group('immutability and value semantics', () {
    test('collections are unmodifiable', () {
      final task = fullTask();
      expect(() => task.tags.add(otherId), throwsUnsupportedError);
      expect(
        () => task.checklist.add(const ChecklistItem(title: 'x')),
        throwsUnsupportedError,
      );
    });

    test('value equality and hashCode', () {
      expect(fullTask(), fullTask());
      expect(fullTask().hashCode, fullTask().hashCode);
      expect(fullTask(), isNot(bareTask()));
      expect(
        fullTask().copyWith(title: const Patch('other')),
        isNot(fullTask()),
      );
    });
  });
}
