import 'dart:convert';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  var nowMicros = DateTime.utc(2026, 8, 24, 10).microsecondsSinceEpoch;
  BlobRef? prev;

  setUp(() {
    nowMicros = DateTime.utc(2026, 8, 24, 10).microsecondsSinceEpoch;
    prev = null;
  });

  DateTime clock() {
    nowMicros += 1000000;
    return DateTime.fromMicrosecondsSinceEpoch(nowMicros, isUtc: true);
  }

  StoredEvent emit(
    TaskEvent event, {
    DateTime? ts,
    Attribution by = const Attribution.user(),
  }) {
    final sealed = Event.seal(
      event.toDraft(source: 'sai/tui', by: by),
      prev: prev,
      ts: ts ?? clock(),
    );
    final id = sealed.deriveId();
    prev = id;
    return StoredEvent(id: id, event: sealed);
  }

  StoredEvent chat(String text) {
    final sealed = Event.seal(
      EventDraft(
        type: EventTypes.chatMessage,
        actor: Actor.user,
        source: 'sai/tui',
        payload: {'text': text},
      ),
      prev: prev,
      ts: clock(),
    );
    final id = sealed.deriveId();
    prev = id;
    return StoredEvent(id: id, event: sealed);
  }

  TaskProjection applyAll(Iterable<StoredEvent> events) =>
      events.fold(TaskProjection.empty, (p, e) => p.apply(e));

  group('empty', () {
    test('holds nothing', () {
      expect(TaskProjection.empty.tasks, isEmpty);
      expect(TaskProjection.empty.areas, isEmpty);
      expect(TaskProjection.empty.projects, isEmpty);
      expect(TaskProjection.empty.headings, isEmpty);
      expect(TaskProjection.empty.tags, isEmpty);
      expect(TaskProjection.empty.lastEventId, isNull);
      expect(TaskProjection.empty.eventCount, 0);
    });

    test('an archive of only chat events replays to no tasks', () {
      final p = applyAll([chat('a'), chat('b')]);
      expect(p.tasks, isEmpty);
      expect(p.eventCount, 2);
      expect(p.lastEventId, isNotNull);
    });
  });

  group('task lifecycle', () {
    test('create fills defaults from the event', () {
      final created = emit(TaskCreated(title: 'Buy milk'));
      final p = TaskProjection.empty.apply(created);
      final task = p.task(created.id)!;
      expect(task.id, created.id);
      expect(task.title, 'Buy milk');
      expect(task.createdAt, created.event.ts);
      expect(task.modifiedAt, created.event.ts);
      expect(task.status, TaskStatus.open);
      expect(p.eventCount, 1);
      expect(p.lastEventId, created.id);
    });

    test('an imported create keeps its own created_at but not modifiedAt', () {
      final imported = DateTime.utc(2020, 1, 1);
      final created = emit(
        TaskCreated(
          title: 'Old friend',
          createdAt: imported,
          external: const ExternalRef(system: 'things3', id: 'T-1'),
        ),
        by: const Attribution.system(),
      );
      final task = TaskProjection.empty.apply(created).task(created.id)!;
      expect(task.createdAt, imported);
      expect(task.modifiedAt, created.event.ts);
    });

    test('edit patches only the named fields and advances modifiedAt', () {
      final created = emit(TaskCreated(title: 'Buy milk', notes: 'oat'));
      final edited = emit(
        TaskEdited(
          created.id,
          title: const Patch('Buy oat milk'),
          deadline: const Patch(CalendarDate(2026, 9, 1)),
        ),
      );
      final task = applyAll([created, edited]).task(created.id)!;
      expect(task.title, 'Buy oat milk');
      expect(task.notes, 'oat');
      expect(task.deadline, const CalendarDate(2026, 9, 1));
      expect(task.createdAt, created.event.ts);
      expect(task.modifiedAt, edited.event.ts);
    });

    test('an explicit at overrides the completion stamp', () {
      final created = emit(TaskCreated(title: 'x'));
      final at = DateTime.utc(2026, 8, 24, 12);
      final completed = applyAll([
        created,
        emit(TaskCompleted(created.id, at: at)),
      ]).task(created.id)!;
      expect(completed.completedAt, at);
      expect(completed.status, TaskStatus.completed);
    });

    test('complete defaults its stamp to the event ts', () {
      final created = emit(TaskCreated(title: 'x'));
      final done = emit(TaskCompleted(created.id));
      final task = applyAll([created, done]).task(created.id)!;
      expect(task.completedAt, done.event.ts);
    });

    test('cancel replaces completion; reopen clears both', () {
      final created = emit(TaskCreated(title: 'x'));
      final done = emit(TaskCompleted(created.id));
      final cancelled = emit(TaskCancelled(created.id));
      final afterCancel = applyAll([created, done, cancelled])
          .task(created.id)!;
      expect(afterCancel.status, TaskStatus.cancelled);
      expect(afterCancel.completedAt, isNull);
      expect(afterCancel.cancelledAt, cancelled.event.ts);

      final reopened = emit(TaskReopened(created.id));
      final afterReopen = applyAll([created, done, cancelled, reopened])
          .task(created.id)!;
      expect(afterReopen.status, TaskStatus.open);
      expect(afterReopen.completedAt, isNull);
      expect(afterReopen.cancelledAt, isNull);
    });

    test('checklist replacement, including to empty', () {
      final created = emit(
        TaskCreated(
          title: 'x',
          checklist: [const ChecklistItem(title: 'a')],
        ),
      );
      final replaced = emit(
        TaskChecklistSet(created.id, [
          const ChecklistItem(title: 'b'),
          const ChecklistItem(title: 'c'),
        ]),
      );
      final emptied = emit(TaskChecklistSet(created.id, const []));
      expect(applyAll([created, replaced]).task(created.id)!.checklist, [
        const ChecklistItem(title: 'b'),
        const ChecklistItem(title: 'c'),
      ]);
      expect(
        applyAll([created, replaced, emptied]).task(created.id)!.checklist,
        isEmpty,
      );
    });
  });

  group('placement', () {
    test('move into a project, under its heading, into an area, and home', () {
      final area = emit(AreaCreated(title: 'Home'));
      final project = emit(ProjectCreated(title: 'Kitchen'));
      final heading = emit(
        HeadingCreated(project: project.id, title: 'Demolition'),
      );
      final created = emit(TaskCreated(title: 'x'));

      final intoProject = emit(TaskMoved(created.id, project: project.id));
      var p = applyAll([area, project, heading, created, intoProject]);
      expect(p.task(created.id)!.project, project.id);

      final underHeading = emit(
        TaskMoved(created.id, project: project.id, heading: heading.id),
      );
      p = applyAll([
        area,
        project,
        heading,
        created,
        intoProject,
        underHeading,
      ]);
      expect(p.task(created.id)!.heading, heading.id);
      expect(p.task(created.id)!.project, project.id);

      final intoArea = emit(TaskMoved(created.id, area: area.id));
      p = applyAll([
        area,
        project,
        heading,
        created,
        intoProject,
        underHeading,
        intoArea,
      ]);
      expect(p.task(created.id)!.area, area.id);
      expect(p.task(created.id)!.project, isNull);
      expect(p.task(created.id)!.heading, isNull);

      final home = emit(TaskMoved(created.id));
      p = applyAll([
        area,
        project,
        heading,
        created,
        intoProject,
        underHeading,
        intoArea,
        home,
      ]);
      expect(p.task(created.id)!.project, isNull);
      expect(p.task(created.id)!.area, isNull);
      expect(
        listOf(p.task(created.id)!, const CalendarDate(2026, 8, 24)),
        TaskList.inbox,
      );
    });

    test('a heading from another project is refused', () {
      final p1 = emit(ProjectCreated(title: 'One'));
      final p2 = emit(ProjectCreated(title: 'Two'));
      final heading = emit(HeadingCreated(project: p1.id, title: 'H'));
      final created = emit(TaskCreated(title: 'x'));
      final wrong = emit(
        TaskMoved(created.id, project: p2.id, heading: heading.id),
      );
      expect(
        () => applyAll([p1, p2, heading, created, wrong]),
        throwsA(isA<TaskProjectionError>()),
      );
    });

    test('creating a task in an unknown project is refused', () {
      final ghost = BlobRef.sha256OfBytes(utf8.encode('ghost'));
      final created = emit(TaskCreated(title: 'x', project: ghost));
      expect(
        () => TaskProjection.empty.apply(created),
        throwsA(isA<TaskProjectionError>()),
      );
    });
  });

  group('delete and restore', () {
    test('a deleted task leaves the lists but stays in the trash', () {
      const today = CalendarDate(2026, 8, 24);
      final created = emit(TaskCreated(title: 'x'));
      final deleted = emit(TaskDeleted(created.id));
      final p = applyAll([created, deleted]);
      expect(p.list(TaskList.inbox, today: today), isEmpty);
      expect(p.trash().map((t) => t.id), [created.id]);
      expect(p.task(created.id), isNotNull);

      final restored = emit(TaskRestored(created.id));
      final back = applyAll([created, deleted, restored]);
      expect(back.list(TaskList.inbox, today: today).map((t) => t.id), [
        created.id,
      ]);
      expect(back.trash(), isEmpty);
    });

    test(
      'a task in a deleted project is hidden from lists, not from itself',
      () {
        const today = CalendarDate(2026, 8, 24);
        final project = emit(ProjectCreated(title: 'P'));
        final created = emit(TaskCreated(title: 'x', project: project.id));
        final gone = emit(ProjectDeleted(project.id));
        final p = applyAll([project, created, gone]);
        expect(p.list(TaskList.anytime, today: today), isEmpty);
        final task = p.task(created.id)!;
        expect(listOf(task, today), TaskList.anytime);

        final back = emit(ProjectRestored(project.id));
        expect(
          applyAll([project, created, gone, back])
              .list(TaskList.anytime, today: today)
              .map((t) => t.id),
          [created.id],
        );
      },
    );
  });

  group('containers', () {
    test('area, project, heading and tag edits apply', () {
      final area = emit(AreaCreated(title: 'Home'));
      final project = emit(ProjectCreated(title: 'Kitchen', area: area.id));
      final heading = emit(HeadingCreated(project: project.id, title: 'H'));
      final tag = emit(TagCreated(title: 'errand'));
      final p = applyAll([
        area,
        project,
        heading,
        tag,
        emit(AreaEdited(area.id, title: const Patch('House'))),
        emit(ProjectEdited(project.id, area: const Patch(null))),
        emit(HeadingEdited(heading.id, title: const Patch('Prep'))),
        emit(TagEdited(tag.id, title: const Patch('errands'))),
      ]);
      expect(p.areas[area.id]!.title, 'House');
      expect(p.projects[project.id]!.area, isNull);
      expect(p.headings[heading.id]!.title, 'Prep');
      expect(p.tags[tag.id]!.title, 'errands');
    });

    test('a project in an unknown area is refused', () {
      final ghost = BlobRef.sha256OfBytes(utf8.encode('ghost'));
      final created = emit(ProjectCreated(title: 'P', area: ghost));
      expect(
        () => TaskProjection.empty.apply(created),
        throwsA(isA<TaskProjectionError>()),
      );
    });
  });

  group('strictness', () {
    test('an unknown subject names the event id', () {
      final ghost = BlobRef.sha256OfBytes(utf8.encode('ghost'));
      final edit = emit(TaskEdited(ghost, title: const Patch('x')));
      expect(
        () => TaskProjection.empty.apply(edit),
        throwsA(
          isA<TaskProjectionError>().having(
            (e) => e.toString(),
            'message',
            contains(edit.id.toString()),
          ),
        ),
      );
    });

    test('a subject of the wrong kind is refused', () {
      final project = emit(ProjectCreated(title: 'P'));
      final wrong = emit(TaskEdited(project.id, title: const Patch('x')));
      expect(
        () => applyAll([project, wrong]),
        throwsA(isA<TaskProjectionError>()),
      );
    });
  });

  group('replay', () {
    List<StoredEvent> history() {
      final area = emit(AreaCreated(title: 'Home'));
      final project = emit(ProjectCreated(title: 'Kitchen', area: area.id));
      final heading = emit(HeadingCreated(project: project.id, title: 'Prep'));
      final tag = emit(TagCreated(title: 'errand'));
      final events = <StoredEvent>[area, project, heading, tag, chat('hello')];
      final tasks = <StoredEvent>[];
      for (var i = 0; i < 5; i++) {
        final t = emit(
          TaskCreated(
            title: 'task $i',
            when: i.isEven
                ? TaskWhen.date(CalendarDate(2026, 8, 20 + i))
                : TaskWhen.none,
            tags: i == 0 ? [tag.id] : const [],
          ),
        );
        tasks.add(t);
        events.add(t);
      }
      events.addAll([
        emit(TaskMoved(tasks[0].id, project: project.id, heading: heading.id)),
        emit(TaskMoved(tasks[1].id, area: area.id)),
        emit(TaskEdited(tasks[2].id, notes: const Patch('note'))),
        emit(TaskCompleted(tasks[3].id)),
        emit(TaskCancelled(tasks[4].id)),
        chat('interleaved'),
        emit(TaskChecklistSet(tasks[2].id, [const ChecklistItem(title: 'a')])),
        emit(TaskDeleted(tasks[1].id)),
        emit(TaskReopened(tasks[3].id)),
        emit(TagEdited(tag.id, title: const Patch('errands'))),
        emit(
          TaskEdited(
            tasks[0].id,
            deadline: const Patch(CalendarDate(2026, 9, 1)),
          ),
        ),
      ]);
      return events;
    }

    test('replay equals fold(apply) — the ADR claim', () {
      final events = history();
      final replayed = TaskProjection.replay(events);
      final folded = applyAll(events);
      expect(replayed.toJson(), folded.toJson());
      expect(replayed.eventCount, events.length);
      expect(replayed.lastEventId, events.last.id);
    });

    test('replaying twice is stable and apply never mutates its receiver', () {
      final events = history();
      final once = TaskProjection.replay(events);
      final twice = TaskProjection.replay(events);
      expect(once.toJson(), twice.toJson());

      final base = TaskProjection.replay(events.take(4).toList());
      final baseJson = jsonEncode(base.toJson());
      base.apply(events[4]);
      expect(jsonEncode(base.toJson()), baseJson);
    });

    test('the whole projection round-trips through JSON', () {
      final p = TaskProjection.replay(history());
      final back = TaskProjection.fromJson(p.toJson());
      expect(back.toJson(), p.toJson());
      expect(back.lastEventId, p.lastEventId);
      expect(back.eventCount, p.eventCount);
    });
  });

  group('queries', () {
    test('byExternal finds an imported task', () {
      final created = emit(
        TaskCreated(
          title: 'imported',
          external: const ExternalRef(system: 'things3', id: 'T-42'),
        ),
        by: const Attribution.system(),
      );
      final p = TaskProjection.empty.apply(created);
      expect(p.byExternal('things3', 'T-42')?.id, created.id);
      expect(p.byExternal('things3', 'nope'), isNull);
    });

    test('lists come back deterministically sorted', () {
      const today = CalendarDate(2026, 8, 24);
      final t1 = emit(
        TaskCreated(
          title: 'later',
          when: TaskWhen.date(const CalendarDate(2026, 8, 26)),
        ),
      );
      final t2 = emit(
        TaskCreated(
          title: 'sooner',
          when: TaskWhen.date(const CalendarDate(2026, 8, 25)),
        ),
      );
      final p = applyAll([t1, t2]);
      expect(p.list(TaskList.upcoming, today: today).map((t) => t.title), [
        'sooner',
        'later',
      ]);
    });

    test('inProject and underHeading answer from placement', () {
      final project = emit(ProjectCreated(title: 'P'));
      final heading = emit(HeadingCreated(project: project.id, title: 'H'));
      final inP = emit(TaskCreated(title: 'a', project: project.id));
      final underH = emit(
        TaskCreated(title: 'b', project: project.id, heading: heading.id),
      );
      final elsewhere = emit(TaskCreated(title: 'c'));
      final p = applyAll([project, heading, inP, underH, elsewhere]);
      expect(p.inProject(project.id).map((t) => t.title).toSet(), {'a', 'b'});
      expect(p.underHeading(heading.id).map((t) => t.title), ['b']);
    });
  });
}
