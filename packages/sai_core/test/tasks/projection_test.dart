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
      final at = DateTime.utc(2026, 8, 24, 9);
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

    test('a heading of any live project is a destination when the move '
        'names that project (#98)', () {
      final p1 = emit(ProjectCreated(title: 'One'));
      final p2 = emit(ProjectCreated(title: 'Two'));
      final heading = emit(HeadingCreated(project: p2.id, title: 'H'));
      final created = emit(TaskCreated(title: 'x', project: p1.id));
      final moved = emit(
        TaskMoved(created.id, project: p2.id, heading: heading.id),
      );
      final p = applyAll([p1, p2, heading, created, moved]);
      expect(p.task(created.id)!.project, p2.id);
      expect(p.task(created.id)!.heading, heading.id);
      expect(p.underHeading(heading.id).map((t) => t.id), [created.id]);
    });

    test('an archived project or area refuses a move with a reason', () {
      final project = emit(ProjectCreated(title: 'P'));
      final area = emit(AreaCreated(title: 'A'));
      final created = emit(TaskCreated(title: 'x'));
      final base = applyAll([
        project,
        area,
        created,
        emit(ProjectArchived(project.id)),
        emit(AreaArchived(area.id)),
      ]);
      for (final event in [
        TaskMoved(created.id, project: project.id),
        TaskMoved(created.id, area: area.id),
      ]) {
        expect(
          () => base.apply(emit(event)),
          throwsA(
            isA<TaskProjectionError>().having(
              (e) => e.reason,
              'reason',
              contains('archived'),
            ),
          ),
        );
      }
    });

    test('a move without an anchor lands last in the destination group', () {
      final project = emit(ProjectCreated(title: 'P'));
      final a = emit(TaskCreated(title: 'a', project: project.id));
      final b = emit(TaskCreated(title: 'b', project: project.id));
      final x = emit(TaskCreated(title: 'x'));
      final p = applyAll([
        project,
        a,
        b,
        x,
        emit(TaskMoved(x.id, project: project.id)),
      ]);
      expect(p.inProject(project.id).map((t) => t.title), ['a', 'b', 'x']);
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

  group('persisted task ordering', () {
    const today = CalendarDate(2026, 8, 24);

    test(
      'creation appends and move supports first, after, and legacy append',
      () {
        final a = emit(TaskCreated(title: 'a'));
        final b = emit(TaskCreated(title: 'b'));
        final c = emit(TaskCreated(title: 'c'));
        var p = applyAll([
          a,
          b,
          c,
          emit(TaskMoved(c.id, after: const Patch(null))),
        ]);
        expect(p.list(TaskList.inbox, today: today).map((t) => t.title), [
          'c',
          'a',
          'b',
        ]);

        p = p.apply(emit(TaskMoved(c.id, after: Patch(a.id))));
        expect(p.list(TaskList.inbox, today: today).map((t) => t.title), [
          'a',
          'c',
          'b',
        ]);

        p = p.apply(emit(TaskMoved(c.id)));
        expect(p.list(TaskList.inbox, today: today).map((t) => t.title), [
          'a',
          'b',
          'c',
        ]);
      },
    );

    test('Today order is independent from structural order', () {
      final project = emit(ProjectCreated(title: 'P'));
      final a = emit(
        TaskCreated(
          title: 'a',
          project: project.id,
          when: const TaskWhen.date(today),
        ),
      );
      final b = emit(
        TaskCreated(
          title: 'b',
          project: project.id,
          when: const TaskWhen.date(today),
        ),
      );
      final c = emit(
        TaskCreated(
          title: 'c',
          project: project.id,
          when: const TaskWhen.date(today),
        ),
      );
      final p = applyAll([
        project,
        a,
        b,
        c,
        emit(TaskMoved(c.id, project: project.id, after: const Patch(null))),
        emit(TaskReordered(b.id, list: TaskList.today, after: null)),
      ]);
      expect(p.inProject(project.id).map((t) => t.title), ['c', 'a', 'b']);
      expect(p.list(TaskList.today, today: today).map((t) => t.title), [
        'b',
        'a',
        'c',
      ]);
    });

    test('completion and deletion filter without losing either position', () {
      final a = emit(TaskCreated(title: 'a', when: const TaskWhen.date(today)));
      final b = emit(TaskCreated(title: 'b', when: const TaskWhen.date(today)));
      final c = emit(TaskCreated(title: 'c', when: const TaskWhen.date(today)));
      final ordered = [
        a,
        b,
        c,
        emit(TaskMoved(c.id, after: const Patch(null))),
        emit(TaskReordered(c.id, list: TaskList.today, after: null)),
      ];
      final hidden = applyAll([
        ...ordered,
        emit(TaskCompleted(c.id)),
        emit(TaskDeleted(c.id)),
      ]);
      expect(hidden.list(TaskList.today, today: today).map((t) => t.title), [
        'a',
        'b',
      ]);
      final restored = hidden
          .apply(emit(TaskRestored(c.id)))
          .apply(emit(TaskReopened(c.id)));
      expect(restored.list(TaskList.today, today: today).map((t) => t.title), [
        'c',
        'a',
        'b',
      ]);
      final inbox = restored.apply(
        emit(TaskEdited(c.id, when: const Patch(TaskWhen.none))),
      );
      expect(inbox.list(TaskList.inbox, today: today).map((t) => t.title), [
        'c',
      ]);
    });

    test('unknown, self, and cross-group structural anchors are refused', () {
      final project = emit(ProjectCreated(title: 'P'));
      final inbox = emit(TaskCreated(title: 'inbox'));
      final filed = emit(TaskCreated(title: 'filed', project: project.id));
      final ghost = BlobRef.sha256OfBytes(utf8.encode('ghost-anchor'));
      final base = applyAll([project, inbox, filed]);
      for (final event in [
        TaskMoved(inbox.id, after: Patch(ghost)),
        TaskMoved(inbox.id, after: Patch(inbox.id)),
        TaskMoved(inbox.id, after: Patch(filed.id)),
      ]) {
        expect(
          () => base.apply(emit(event)),
          throwsA(isA<TaskProjectionError>()),
        );
      }
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

  group('deleted containers refuse new members', () {
    test('creating or moving into a deleted project is refused', () {
      final project = emit(ProjectCreated(title: 'P'));
      final gone = emit(ProjectDeleted(project.id));
      final intoDeleted = emit(TaskCreated(title: 'x', project: project.id));
      expect(
        () => applyAll([project, gone, intoDeleted]),
        throwsA(isA<TaskProjectionError>()),
      );

      final task = emit(TaskCreated(title: 'x'));
      final moveIn = emit(TaskMoved(task.id, project: project.id));
      expect(
        () => applyAll([project, gone, task, moveIn]),
        throwsA(isA<TaskProjectionError>()),
      );
    });

    test('a heading cannot be created in a deleted project', () {
      final project = emit(ProjectCreated(title: 'P'));
      final gone = emit(ProjectDeleted(project.id));
      final heading = emit(HeadingCreated(project: project.id, title: 'H'));
      expect(
        () => applyAll([project, gone, heading]),
        throwsA(isA<TaskProjectionError>()),
      );
    });

    test('a heading cannot be created in an archived project', () {
      final project = emit(ProjectCreated(title: 'P'));
      final shelved = emit(ProjectArchived(project.id));
      final heading = emit(HeadingCreated(project: project.id, title: 'H'));
      expect(
        () => applyAll([project, shelved, heading]),
        throwsA(
          isA<TaskProjectionError>().having(
            (e) => e.reason,
            'reason',
            contains('archived'),
          ),
        ),
      );
    });

    test('a deleted tag cannot be attached', () {
      final tag = emit(TagCreated(title: 't'));
      final gone = emit(TagDeleted(tag.id));
      final tagged = emit(TaskCreated(title: 'x', tags: [tag.id]));
      expect(
        () => applyAll([tag, gone, tagged]),
        throwsA(isA<TaskProjectionError>()),
      );
    });

    test(
      'a deleted area refuses projects and a deleted parent refuses tags',
      () {
        final area = emit(AreaCreated(title: 'A'));
        final areaGone = emit(AreaDeleted(area.id));
        final project = emit(ProjectCreated(title: 'P', area: area.id));
        expect(
          () => applyAll([area, areaGone, project]),
          throwsA(isA<TaskProjectionError>()),
        );

        final parent = emit(TagCreated(title: 'p'));
        final parentGone = emit(TagDeleted(parent.id));
        final child = emit(TagCreated(title: 'c', parent: parent.id));
        expect(
          () => applyAll([parent, parentGone, child]),
          throwsA(isA<TaskProjectionError>()),
        );
      },
    );

    test('restoring the container makes it a valid target again', () {
      final project = emit(ProjectCreated(title: 'P'));
      final gone = emit(ProjectDeleted(project.id));
      final back = emit(ProjectRestored(project.id));
      final task = emit(TaskCreated(title: 'x', project: project.id));
      final p = applyAll([project, gone, back, task]);
      expect(p.task(task.id)!.project, project.id);
    });
  });

  group('tag parent cycles', () {
    test('a tag cannot be its own parent', () {
      final tag = emit(TagCreated(title: 't'));
      final selfParent = emit(TagEdited(tag.id, parent: Patch(tag.id)));
      expect(
        () => applyAll([tag, selfParent]),
        throwsA(isA<TaskProjectionError>()),
      );
    });

    test('a two-tag cycle is refused', () {
      final a = emit(TagCreated(title: 'a'));
      final b = emit(TagCreated(title: 'b', parent: a.id));
      final cycle = emit(TagEdited(a.id, parent: Patch(b.id)));
      expect(
        () => applyAll([a, b, cycle]),
        throwsA(isA<TaskProjectionError>()),
      );
    });

    test('reparenting within a chain stays legal', () {
      final a = emit(TagCreated(title: 'a'));
      final b = emit(TagCreated(title: 'b', parent: a.id));
      final c = emit(TagCreated(title: 'c', parent: b.id));
      final flatten = emit(TagEdited(c.id, parent: Patch(a.id)));
      final p = applyAll([a, b, c, flatten]);
      expect(p.tags[c.id]!.parent, a.id);
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

    test('malformed blobrefs fail as FormatException', () {
      final json = TaskProjection.empty.toJson();
      for (final value in [7, '', 'not-a-ref']) {
        final malformed = Map<String, Object?>.from(json)
          ..['last_event'] = value;
        expect(
          () => TaskProjection.fromJson(malformed),
          throwsFormatException,
          reason: 'last_event: $value',
        );
      }

      for (final value in [null, 7, '', 'not-a-ref']) {
        final malformed = Map<String, Object?>.from(json)
          ..['externals'] = {'things3:T-1': value};
        expect(
          () => TaskProjection.fromJson(malformed),
          throwsFormatException,
          reason: 'external id: $value',
        );
      }
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

    test('list() serves the view unions, not just the partition', () {
      const today = CalendarDate(2026, 8, 24);
      final project = emit(ProjectCreated(title: 'P'));
      final filedToday = emit(
        TaskCreated(
          title: 'filed today',
          project: project.id,
          when: TaskWhen.date(today),
        ),
      );
      final dueLater = emit(
        TaskCreated(
          title: 'due later',
          project: project.id,
          deadline: const CalendarDate(2026, 9, 1),
        ),
      );
      final p = applyAll([project, filedToday, dueLater]);
      expect(
        p.list(TaskList.anytime, today: today).map((t) => t.title).toSet(),
        {'filed today', 'due later'},
      );
      expect(p.list(TaskList.upcoming, today: today).map((t) => t.title), [
        'due later',
      ]);
      expect(p.list(TaskList.today, today: today).map((t) => t.title), [
        'filed today',
      ]);
    });

    test('placement queries serve open tasks in living containers only', () {
      final project = emit(ProjectCreated(title: 'P'));
      final heading = emit(HeadingCreated(project: project.id, title: 'H'));
      final open = emit(TaskCreated(title: 'open', project: project.id));
      final done = emit(TaskCreated(title: 'done', project: project.id));
      final finish = emit(TaskCompleted(done.id));
      final under = emit(
        TaskCreated(title: 'under', project: project.id, heading: heading.id),
      );
      final headingGone = emit(HeadingDeleted(heading.id));
      final p = applyAll([
        project,
        heading,
        open,
        done,
        finish,
        under,
        headingGone,
      ]);
      expect(p.inProject(project.id).map((t) => t.title), ['open']);
      expect(p.underHeading(heading.id), isEmpty);
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

  group('persisted container ordering', () {
    test('areas, projects and headings replay in creation order', () {
      final b = emit(AreaCreated(title: 'b'));
      final a = emit(AreaCreated(title: 'a'));
      final p2 = emit(ProjectCreated(title: 'p2', area: a.id));
      final p1 = emit(ProjectCreated(title: 'p1', area: a.id));
      final h2 = emit(HeadingCreated(project: p1.id, title: 'h2'));
      final h1 = emit(HeadingCreated(project: p1.id, title: 'h1'));
      final p = applyAll([b, a, p2, p1, h2, h1]);
      expect(p.liveAreas().map((x) => x.id), [b.id, a.id]);
      expect(p.liveProjects().map((x) => x.id), [p2.id, p1.id]);
      expect(p.headingsOf(p1.id).map((x) => x.id), [h2.id, h1.id]);
      expect(
        TaskProjection.replay([b, a, p2, p1, h2, h1]).toJson(),
        p.toJson(),
      );
    });

    test('a reorder moves a container to first and after a sibling', () {
      final a = emit(AreaCreated(title: 'a'));
      final b = emit(AreaCreated(title: 'b'));
      final c = emit(AreaCreated(title: 'c'));
      var p = applyAll([a, b, c, emit(AreaReordered(c.id, after: null))]);
      expect(p.areaOrder, [c.id, a.id, b.id]);
      p = p.apply(emit(AreaReordered(c.id, after: a.id)));
      expect(p.areaOrder, [a.id, c.id, b.id]);
      expect(p.areaPredecessor(c.id), a.id);
      expect(p.areaPredecessor(a.id), isNull);
    });

    test('one project sequence serves every area group', () {
      final home = emit(AreaCreated(title: 'home'));
      final work = emit(AreaCreated(title: 'work'));
      final h1 = emit(ProjectCreated(title: 'h1', area: home.id));
      final w1 = emit(ProjectCreated(title: 'w1', area: work.id));
      final h2 = emit(ProjectCreated(title: 'h2', area: home.id));
      final loose = emit(ProjectCreated(title: 'loose'));
      var p = applyAll([home, work, h1, w1, h2, loose]);
      expect(p.projectPredecessor(h2.id), h1.id);
      expect(p.projectPredecessor(w1.id), isNull);
      p = p.apply(emit(ProjectReordered(h2.id, after: null)));
      expect(p.projectOrder, [h2.id, h1.id, w1.id, loose.id]);
      expect(
        () => p.apply(emit(ProjectReordered(h1.id, after: w1.id))),
        throwsA(
          isA<TaskProjectionError>().having(
            (e) => e.reason,
            'reason',
            contains('is in another group'),
          ),
        ),
      );
    });

    test('a heading reorders inside its project only', () {
      final p1 = emit(ProjectCreated(title: 'p1'));
      final p2 = emit(ProjectCreated(title: 'p2'));
      final a = emit(HeadingCreated(project: p1.id, title: 'a'));
      final b = emit(HeadingCreated(project: p1.id, title: 'b'));
      final other = emit(HeadingCreated(project: p2.id, title: 'other'));
      var p = applyAll([p1, p2, a, b, other]);
      p = p.apply(emit(HeadingReordered(b.id, after: null)));
      expect(p.headingsOf(p1.id).map((h) => h.id), [b.id, a.id]);
      expect(p.headingPredecessor(a.id), b.id);
      expect(
        () => p.apply(emit(HeadingReordered(a.id, after: other.id))),
        throwsA(
          isA<TaskProjectionError>().having(
            (e) => e.reason,
            'reason',
            'the heading anchor ${other.id} is in another group',
          ),
        ),
      );
    });

    test('unknown, self, wrong-kind and not-live container anchors are '
        'refused', () {
      final a = emit(AreaCreated(title: 'a'));
      final b = emit(AreaCreated(title: 'b'));
      final project = emit(ProjectCreated(title: 'p'));
      final p = applyAll([a, b, project, emit(AreaArchived(b.id))]);
      String reasonOf(TaskEvent event) {
        try {
          p.apply(emit(event));
        } on TaskProjectionError catch (e) {
          return e.reason;
        }
        fail('applied');
      }

      final unknown = BlobRef.sha256OfBytes([9]);
      expect(
        reasonOf(AreaReordered(a.id, after: unknown)),
        'unknown area: $unknown',
      );
      expect(
        reasonOf(AreaReordered(a.id, after: a.id)),
        'an area cannot be ordered after itself',
      );
      expect(
        reasonOf(AreaReordered(a.id, after: project.id)),
        '${project.id} is a project, not a area',
      );
      expect(
        reasonOf(AreaReordered(a.id, after: b.id)),
        'the area anchor ${b.id} is not live',
      );
      expect(
        reasonOf(AreaReordered(b.id, after: null)),
        'the area ${b.id} is not live',
      );
      expect(
        reasonOf(ProjectReordered(project.id, after: project.id)),
        'a project cannot be ordered after itself',
      );
    });

    test("changing a project's area appends it to the end of the new group; "
        'rewriting the same area leaves the order alone', () {
      final home = emit(AreaCreated(title: 'home'));
      final work = emit(AreaCreated(title: 'work'));
      final h1 = emit(ProjectCreated(title: 'h1', area: home.id));
      final w1 = emit(ProjectCreated(title: 'w1', area: work.id));
      final h2 = emit(ProjectCreated(title: 'h2', area: home.id));
      var p = applyAll([home, work, h1, w1, h2]);
      p = p.apply(emit(ProjectEdited(h1.id, area: Patch(work.id))));
      expect(p.projectOrder, [w1.id, h1.id, h2.id]);
      p = p.apply(emit(ProjectReordered(h1.id, after: null)));
      expect(p.projectOrder, [h1.id, w1.id, h2.id]);
      p = p.apply(
        emit(
          ProjectEdited(h1.id, area: Patch(work.id), title: const Patch('x')),
        ),
      );
      expect(p.projectOrder, [h1.id, w1.id, h2.id]);
    });

    test('a project whose area is archived groups as standalone', () {
      final home = emit(AreaCreated(title: 'home'));
      final h1 = emit(ProjectCreated(title: 'h1', area: home.id));
      final loose = emit(ProjectCreated(title: 'loose'));
      final p = applyAll([home, h1, loose, emit(AreaArchived(home.id))]);
      expect(p.groupOf(p.projects[h1.id]!), isNull);
      expect(p.projectPredecessor(loose.id), h1.id);
      expect(
        p.apply(emit(ProjectReordered(loose.id, after: null))).projectOrder,
        [loose.id, h1.id],
      );
    });
  });

  group('archiving', () {
    const today = CalendarDate(2026, 8, 24);

    test('archiving hides a container\'s tasks; unarchiving reveals them at '
        'their positions', () {
      final project = emit(ProjectCreated(title: 'P'));
      final a = emit(TaskCreated(title: 'a', project: project.id));
      final b = emit(TaskCreated(title: 'b'));
      final c = emit(TaskCreated(title: 'c', project: project.id));
      var p = applyAll([project, a, b, c]);
      p = p.apply(emit(ProjectArchived(project.id)));
      expect(p.projects[project.id]!.archivedAt, isNotNull);
      expect(p.list(TaskList.anytime, today: today), isEmpty);
      expect(p.inProject(project.id), isEmpty);
      expect(p.inProject(project.id, archived: true).map((t) => t.title), [
        'a',
        'c',
      ]);
      expect(p.liveProjects(), isEmpty);
      expect(p.archivedProjects().map((x) => x.id), [project.id]);
      expect(p.projectOrder, [project.id]);
      p = p.apply(emit(ProjectUnarchived(project.id)));
      expect(p.inProject(project.id).map((t) => t.title), ['a', 'c']);
      expect(p.archivedProjects(), isEmpty);
    });

    test('archived containers refuse new members', () {
      final area = emit(AreaCreated(title: 'A'));
      final project = emit(ProjectCreated(title: 'P'));
      final task = emit(TaskCreated(title: 't'));
      final p = applyAll([
        area,
        project,
        task,
        emit(AreaArchived(area.id)),
        emit(ProjectArchived(project.id)),
      ]);
      final attempts = <TaskEvent, String>{
        TaskCreated(title: 'x', project: project.id):
            'project ${project.id} is archived',
        TaskMoved(task.id, area: area.id): 'area ${area.id} is archived',
        ProjectCreated(title: 'x', area: area.id):
            'area ${area.id} is archived',
        HeadingCreated(project: project.id, title: 'h'):
            'project ${project.id} is archived',
      };
      for (final MapEntry(key: event, value: reason) in attempts.entries) {
        expect(
          () => p.apply(emit(event)),
          throwsA(
            isA<TaskProjectionError>().having(
              (e) => e.reason,
              'reason',
              reason,
            ),
          ),
          reason: event.type,
        );
      }
    });

    test('a task already in an archived project may still change heading '
        'there; a deleted project refuses even that', () {
      final project = emit(ProjectCreated(title: 'P'));
      final heading = emit(HeadingCreated(project: project.id, title: 'H'));
      final task = emit(
        TaskCreated(title: 't', project: project.id, heading: heading.id),
      );
      final loose = emit(TaskCreated(title: 'l'));
      var p = applyAll([
        project,
        heading,
        task,
        loose,
        emit(ProjectArchived(project.id)),
      ]);
      p = p.apply(emit(TaskMoved(task.id, project: project.id)));
      expect(p.tasks[task.id]!.heading, isNull);
      expect(p.tasks[task.id]!.project, project.id);
      expect(
        () => p.apply(emit(TaskMoved(loose.id, project: project.id))),
        throwsA(
          isA<TaskProjectionError>().having(
            (e) => e.reason,
            'reason',
            'project ${project.id} is archived',
          ),
        ),
      );
      p = p.apply(emit(ProjectDeleted(project.id)));
      expect(
        () => p.apply(
          emit(TaskMoved(task.id, project: project.id, heading: heading.id)),
        ),
        throwsA(
          isA<TaskProjectionError>().having(
            (e) => e.reason,
            'reason',
            'project ${project.id} is deleted',
          ),
        ),
      );
    });

    test('archiving twice overwrites the stamp; unarchiving a live container '
        'is a no-op; archive and delete are independent', () {
      final area = emit(AreaCreated(title: 'A'));
      var p = applyAll([area, emit(AreaUnarchived(area.id))]);
      expect(p.areas[area.id]!.archivedAt, isNull);
      p = p.apply(emit(AreaArchived(area.id)));
      final first = p.areas[area.id]!.archivedAt;
      p = p.apply(emit(AreaArchived(area.id)));
      expect(p.areas[area.id]!.archivedAt!.isAfter(first!), isTrue);
      p = p.apply(emit(AreaDeleted(area.id)));
      expect(p.archivedAreas(), isEmpty);
      expect(p.areas[area.id]!.archivedAt, isNotNull);
      p = p.apply(emit(AreaRestored(area.id)));
      expect(p.archivedAreas().map((a) => a.id), [area.id]);
      expect(p.liveAreas(), isEmpty);
    });

    test('a task in a live project under an archived area stays visible, '
        'and an anchor inside an archived project is not live', () {
      final area = emit(AreaCreated(title: 'A'));
      final project = emit(ProjectCreated(title: 'P', area: area.id));
      final inProject = emit(TaskCreated(title: 'p', project: project.id));
      final direct = emit(TaskCreated(title: 'd', area: area.id));
      final loose = emit(TaskCreated(title: 'l'));
      var p = applyAll([area, project, inProject, direct, loose]);
      p = p.apply(emit(AreaArchived(area.id)));
      expect(p.list(TaskList.anytime, today: today).map((t) => t.title), ['p']);
      expect(p.inArea(area.id), isEmpty);
      expect(p.inArea(area.id, archived: true).map((t) => t.title), ['d']);
      p = p.apply(emit(ProjectArchived(project.id)));
      expect(
        () => p.apply(
          emit(
            TaskMoved(
              loose.id,
              project: project.id,
              after: Patch(inProject.id),
            ),
          ),
        ),
        throwsA(isA<TaskProjectionError>()),
      );
    });

    test('toJson round-trips the sequences and archived_at, and refuses a '
        'sequence missing an id', () {
      final area = emit(AreaCreated(title: 'A'));
      final project = emit(ProjectCreated(title: 'P', area: area.id));
      final heading = emit(HeadingCreated(project: project.id, title: 'H'));
      final p = applyAll([area, project, heading, emit(AreaArchived(area.id))]);
      final json = jsonDecode(jsonEncode(p.toJson()));
      expect(TaskProjection.fromJson(json).toJson(), p.toJson());
      final bad = jsonDecode(jsonEncode(p.toJson())) as Map<String, Object?>;
      bad['heading_order'] = <Object?>[];
      expect(
        () => TaskProjection.fromJson(bad),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'projection.heading_order must contain every heading id exactly once',
          ),
        ),
      );
    });
  });
}
