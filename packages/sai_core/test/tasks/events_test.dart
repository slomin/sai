import 'dart:convert';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  final ts = DateTime.utc(2026, 8, 24, 9, 14, 2, 123, 456);
  final prev = BlobRef.sha256OfBytes(utf8.encode('prev'));
  final taskId = BlobRef.sha256OfBytes(utf8.encode('task'));
  final projectId = BlobRef.sha256OfBytes(utf8.encode('project'));
  final headingId = BlobRef.sha256OfBytes(utf8.encode('heading'));
  final areaId = BlobRef.sha256OfBytes(utf8.encode('area'));
  final tagId = BlobRef.sha256OfBytes(utf8.encode('tag'));

  Event seal(TaskEvent event, {Attribution by = const Attribution.user()}) =>
      Event.seal(
        event.toDraft(source: 'sai/tui', by: by),
        prev: prev,
        ts: ts,
      );

  group('round-trips', () {
    final samples = <TaskEvent>[
      TaskCreated(title: 'Buy milk'),
      TaskCreated(
        title: 'Buy milk',
        notes: 'oat',
        when: TaskWhen.date(const CalendarDate(2026, 8, 24)),
        deadline: const CalendarDate(2026, 8, 30),
        project: projectId,
        heading: headingId,
        tags: [tagId],
        checklist: [const ChecklistItem(title: 'oat')],
        createdAt: DateTime.utc(2020, 1, 1),
        external: const ExternalRef(system: 'things3', id: 'T-1'),
      ),
      TaskEdited(taskId, title: const Patch('New title')),
      TaskEdited(
        taskId,
        notes: const Patch(''),
        when: const Patch(TaskWhen.someday),
        deadline: const Patch(null),
        tags: Patch([tagId]),
      ),
      TaskMoved(taskId, project: projectId, heading: headingId),
      TaskMoved(taskId, area: areaId),
      TaskMoved(taskId),
      TaskMoved(taskId, after: const Patch(null)),
      TaskMoved(taskId, after: Patch(areaId)),
      TaskReordered(taskId, list: TaskList.today, after: null),
      TaskReordered(taskId, list: TaskList.today, after: areaId),
      TaskCompleted(taskId),
      TaskCompleted(taskId, at: DateTime.utc(2026, 8, 24, 12)),
      TaskCancelled(taskId, at: DateTime.utc(2026, 8, 24, 12)),
      TaskReopened(taskId),
      TaskDeleted(taskId),
      TaskRestored(taskId),
      TaskChecklistSet(taskId, [
        ChecklistItem(title: 'oat', completedAt: DateTime.utc(2026, 8, 21)),
        const ChecklistItem(title: 'soy'),
      ]),
      AreaCreated(title: 'Home'),
      AreaEdited(areaId, title: const Patch('House')),
      AreaDeleted(areaId),
      AreaRestored(areaId),
      ProjectCreated(
        title: 'Kitchen',
        notes: 'refit',
        area: areaId,
        when: TaskWhen.someday,
        deadline: const CalendarDate(2027, 1, 1),
        tags: [tagId],
        external: const ExternalRef(system: 'things3', id: 'P-1'),
        createdAt: DateTime.utc(2021, 2, 3),
      ),
      ProjectEdited(
        projectId,
        area: const Patch(null),
        title: const Patch('K'),
      ),
      ProjectDeleted(projectId),
      ProjectRestored(projectId),
      HeadingCreated(project: projectId, title: 'Demolition'),
      HeadingEdited(headingId, title: const Patch('Demo')),
      HeadingDeleted(headingId),
      HeadingRestored(headingId),
      TagCreated(title: 'errand'),
      TagCreated(title: 'deep errand', parent: tagId),
      TagEdited(
        tagId,
        title: const Patch('errands'),
        parent: const Patch(null),
      ),
      TagDeleted(tagId),
      TagRestored(tagId),
    ];

    test('every event seals, encodes and decodes back to itself', () {
      for (final sample in samples) {
        final sealed = seal(sample);
        final line = sealed.encode();
        final back = decodeTaskEvent(Event.decodeLine(line));
        expect(back, isNotNull, reason: sample.type);
        expect(back.runtimeType, sample.runtimeType, reason: sample.type);
        expect(back!.toPayload(), sample.toPayload(), reason: sample.type);
        expect(back.type, sample.type);
      }
    });

    test('all 26 registry types are covered by the samples', () {
      expect(samples.map((s) => s.type).toSet(), TaskEventTypes.all.toSet());
      expect(TaskEventTypes.all, hasLength(26));
    });
  });

  group('the envelope toDraft builds', () {
    test('subject rides in refs; move adds its destination', () {
      expect(seal(TaskEdited(taskId, title: const Patch('x'))).refs, [taskId]);
      expect(
        seal(TaskMoved(taskId, project: projectId, heading: headingId)).refs,
        [taskId, projectId, headingId],
      );
      expect(seal(TaskMoved(taskId, area: areaId)).refs, [taskId, areaId]);
      expect(seal(TaskMoved(taskId)).refs, [taskId]);
      expect(seal(TaskCreated(title: 'x')).refs, isEmpty);
    });

    test('attribution controls actor, model and extra refs', () {
      final user = seal(TaskCompleted(taskId));
      expect(user.actor, Actor.user);
      expect(user.model, isNull);

      const model = ModelRef(provider: 'anthropic', id: 'claude-fable-5');
      final proposal = BlobRef.sha256OfBytes(utf8.encode('proposal'));
      final assistant = seal(
        TaskCompleted(taskId),
        by: Attribution.assistant(model, refs: [proposal]),
      );
      expect(assistant.actor, Actor.assistant);
      expect(assistant.model?.provider, 'anthropic');
      expect(assistant.refs, [taskId, proposal]);

      final import = seal(
        TaskCreated(title: 'x'),
        by: const Attribution.system(),
      );
      expect(import.actor, Actor.system);
    });

    test('withRefs appends without duplicating', () {
      final a = BlobRef.sha256OfBytes(utf8.encode('a'));
      final b = BlobRef.sha256OfBytes(utf8.encode('b'));
      final by = Attribution.user(refs: [a]).withRefs([a, b]);
      expect(by.actor, Actor.user);
      expect(by.refs, [a, b]);

      const model = ModelRef(provider: 'anthropic', id: 'claude-fable-5');
      final assistant = const Attribution.assistant(model).withRefs([b]);
      expect(assistant.model, model);
      expect(assistant.refs, [b]);
    });

    test('container events refuse an assistant attribution', () {
      const model = ModelRef(provider: 'anthropic', id: 'claude-fable-5');
      const by = Attribution.assistant(model);
      // The registry's actor column for area/project/heading/tag rows is
      // user / system; only task.* mutations may be assistant-made (#35).
      for (final event in <TaskEvent>[
        AreaCreated(title: 'A'),
        AreaDeleted(areaId),
        ProjectEdited(projectId, title: const Patch('P')),
        HeadingCreated(project: projectId, title: 'H'),
        TagRestored(tagId),
      ]) {
        expect(
          () => event.toDraft(source: 'sai/tui', by: by),
          throwsArgumentError,
          reason: event.type,
        );
      }
      // Every task.* mutation still may be.
      expect(seal(TaskDeleted(taskId), by: by).actor, Actor.assistant);
    });

    test('a decoded container event with an assistant actor is refused', () {
      const model = ModelRef(provider: 'anthropic', id: 'claude-fable-5');
      final sealed = Event.seal(
        EventDraft(
          type: TaskEventTypes.areaCreate,
          actor: Actor.assistant,
          source: 'sai/tui',
          payload: {'title': 'A'},
          model: model,
        ),
        prev: prev,
        ts: ts,
      );
      expect(() => decodeTaskEvent(sealed), throwsFormatException);
    });
  });

  group('field-set semantics', () {
    test('move distinguishes append, first, and an explicit predecessor', () {
      expect(TaskMoved(taskId).toPayload().containsKey('after'), isFalse);
      expect(
        TaskMoved(taskId, after: const Patch(null)).toPayload()['after'],
        isNull,
      );
      expect(
        TaskMoved(taskId, after: Patch(projectId)).toPayload()['after'],
        projectId.toString(),
      );
    });

    test('absent, null and value survive the wire distinctly', () {
      final cleared = seal(TaskEdited(taskId, deadline: const Patch(null)));
      expect(cleared.encode(), contains('"deadline":null'));
      final decoded = decodeTaskEvent(cleared)! as TaskEdited;
      expect(decoded.deadline, isNotNull);
      expect(decoded.deadline!.value, isNull);
      expect(decoded.title, isNull);
      expect(decoded.tags, isNull);

      final set =
          decodeTaskEvent(
                seal(
                  TaskEdited(
                    taskId,
                    deadline: const Patch(CalendarDate(2026, 9, 1)),
                  ),
                ),
              )!
              as TaskEdited;
      expect(set.deadline!.value, const CalendarDate(2026, 9, 1));
    });

    test('editing when to none writes a literal null', () {
      final sealed = seal(TaskEdited(taskId, when: const Patch(TaskWhen.none)));
      expect(sealed.encode(), contains('"when":null'));
      final decoded = decodeTaskEvent(sealed)! as TaskEdited;
      expect(decoded.when!.value, TaskWhen.none);
    });
  });

  group('decodeTaskEvent skips what is not ours', () {
    test('core log types and unknown types return null', () {
      for (final type in [
        EventTypes.chatMessage,
        EventTypes.toolCall,
        'foo.bar',
        'task.snooze',
      ]) {
        final sealed = Event.seal(
          EventDraft(
            type: type,
            actor: Actor.user,
            source: 'sai/tui',
            payload: {'text': 'hi'},
          ),
          prev: prev,
          ts: ts,
        );
        expect(decodeTaskEvent(sealed), isNull, reason: type);
      }
    });
  });

  group('strict decode', () {
    Event rawEvent(String type, Map<String, Object?> payload) => Event.seal(
      EventDraft(
        type: type,
        actor: Actor.user,
        source: 'sai/tui',
        payload: payload,
      ),
      prev: prev,
      ts: ts,
    );

    test('rejects unknown payload keys', () {
      expect(
        () => decodeTaskEvent(
          rawEvent(TaskEventTypes.taskComplete, {
            'task': taskId.toString(),
            'color': 'red',
          }),
        ),
        throwsFormatException,
      );
    });

    test('rejects a missing or malformed subject', () {
      expect(
        () => decodeTaskEvent(rawEvent(TaskEventTypes.taskComplete, {})),
        throwsFormatException,
      );
      expect(
        () => decodeTaskEvent(
          rawEvent(TaskEventTypes.taskComplete, {'task': 'not-a-ref'}),
        ),
        throwsFormatException,
      );
    });

    test('rejects placement keys on task.edit', () {
      expect(
        () => decodeTaskEvent(
          rawEvent(TaskEventTypes.taskEdit, {
            'task': taskId.toString(),
            'project': projectId.toString(),
          }),
        ),
        throwsFormatException,
      );
    });

    test('rejects an edit with no field keys', () {
      expect(
        () => decodeTaskEvent(
          rawEvent(TaskEventTypes.taskEdit, {'task': taskId.toString()}),
        ),
        throwsFormatException,
      );
    });

    test('rejects a move missing a placement key', () {
      expect(
        () => decodeTaskEvent(
          rawEvent(TaskEventTypes.taskMove, {
            'task': taskId.toString(),
            'project': null,
            'area': null,
          }),
        ),
        throwsFormatException,
      );
    });

    test('Today reorder requires its fixed list and nullable after key', () {
      expect(
        () => decodeTaskEvent(
          rawEvent(TaskEventTypes.taskReorder, {
            'task': taskId.toString(),
            'list': 'today',
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => decodeTaskEvent(
          rawEvent(TaskEventTypes.taskReorder, {
            'task': taskId.toString(),
            'list': 'inbox',
            'after': null,
          }),
        ),
        throwsFormatException,
      );
    });

    test('rejects contradictory placements', () {
      expect(
        () => decodeTaskEvent(
          rawEvent(TaskEventTypes.taskMove, {
            'task': taskId.toString(),
            'project': projectId.toString(),
            'area': areaId.toString(),
            'heading': null,
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => decodeTaskEvent(
          rawEvent(TaskEventTypes.taskMove, {
            'task': taskId.toString(),
            'project': null,
            'area': null,
            'heading': headingId.toString(),
          }),
        ),
        throwsFormatException,
      );
    });

    test('rejects an empty title on create', () {
      expect(
        () =>
            decodeTaskEvent(rawEvent(TaskEventTypes.taskCreate, {'title': ''})),
        throwsFormatException,
      );
    });

    test('rejects created_at without external', () {
      expect(
        () => decodeTaskEvent(
          rawEvent(TaskEventTypes.taskCreate, {
            'title': 'x',
            'created_at': '2020-01-01T00:00:00.000000Z',
          }),
        ),
        throwsFormatException,
      );
    });
  });

  group('construction guards', () {
    test('mirror the decode rules', () {
      expect(() => TaskCreated(title: ''), throwsArgumentError);
      expect(() => TaskCreated(title: 'x', createdAt: ts), throwsArgumentError);
      expect(() => TaskEdited(taskId), throwsArgumentError);
      expect(
        () => TaskMoved(taskId, project: projectId, area: areaId),
        throwsArgumentError,
      );
      expect(() => TaskMoved(taskId, heading: headingId), throwsArgumentError);
      expect(
        () => TaskReordered(taskId, list: TaskList.inbox, after: null),
        throwsArgumentError,
      );
      expect(() => AreaEdited(areaId), throwsArgumentError);
    });
  });

  group('limits', () {
    test('a create with 1 MiB of notes is refused by the envelope', () {
      expect(
        () => seal(TaskCreated(title: 'x', notes: 'y' * (1 << 20))),
        throwsArgumentError,
      );
    });
  });

  group('golden vector', () {
    test('the model doc line is real', () {
      final sealed = Event.seal(
        TaskCreated(title: 'Buy oat milk').toDraft(source: 'sai/tui'),
        prev: null,
        ts: ts,
      );
      final line = sealed.encode();
      expect(line, goldenLine);
      expect(sealed.deriveId().toString(), goldenId);
    });
  });
}

// Filled from the first real run; reproduced in docs/tasks/task-model-v0.md.
const goldenLine =
    '{"actor":"user","payload":{"title":"Buy oat milk"},"prev":null,'
    '"source":"sai/tui","ts":"2026-08-24T09:14:02.123456Z",'
    '"type":"task.create","v":0}';
const goldenId =
    'sha256-b9ce5b9c29fed28862c26cb307c88bbf5bd0935ce4df2b382a888eff91fdde4b';
