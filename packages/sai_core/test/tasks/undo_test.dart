import 'dart:convert';
import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Archive archive;
  late TaskStore store;

  var nowMicros = DateTime.utc(2026, 8, 24, 10).microsecondsSinceEpoch;

  DateTime clock() {
    nowMicros += 1000000;
    return DateTime.fromMicrosecondsSinceEpoch(nowMicros, isUtc: true);
  }

  setUp(() async {
    nowMicros = DateTime.utc(2026, 8, 24, 10).microsecondsSinceEpoch;
    tmp = Directory.systemTemp.createTempSync('sai_undo_test');
    archive = await Archive.open(tmp, clock: clock);
    store = await TaskStore.open(archive, source: 'sai/tui');
  });

  tearDown(() async {
    store.dispose();
    await archive.close();
    tmp.deleteSync(recursive: true);
  });

  List<String> logLines() {
    final dir = Directory('${tmp.path}/events');
    if (!dir.existsSync()) return const [];
    final lines = <String>[];
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      lines.addAll(
        file.readAsStringSync().split('\n').where((l) => l.isNotEmpty),
      );
    }
    return lines;
  }

  group('invertEvent', () {
    final fakeId = BlobRef.sha256OfBytes([1]);

    test('a create inverts to a delete of the minted id', () {
      final inverse = invertEvent(
        TaskCreated(title: 'x'),
        TaskProjection.empty,
        created: fakeId,
      );
      expect(inverse, isA<TaskDeleted>());
      expect((inverse as TaskDeleted).task, fakeId);
    });

    test('an edit inverts to an edit of exactly the patched fields', () async {
      final task = await store.createTask(
        title: 'old title',
        deadline: const CalendarDate(2026, 9, 1),
      );
      final before = store.projection;
      final inverse = invertEvent(
        TaskEdited(
          task,
          title: const Patch('new title'),
          deadline: const Patch(null),
        ),
        before,
        created: fakeId,
      ) as TaskEdited;
      expect(inverse.task, task);
      expect(inverse.title!.value, 'old title');
      expect(inverse.deadline!.value, const CalendarDate(2026, 9, 1));
      expect(inverse.notes, isNull);
      expect(inverse.when, isNull);
      expect(inverse.tags, isNull);
    });

    test('a move inverts to a move back to the prior placement', () async {
      final project = await store.createProject(title: 'P');
      final task = await store.createTask(title: 'x', project: project);
      final inverse = invertEvent(
        TaskMoved(task),
        store.projection,
        created: fakeId,
      ) as TaskMoved;
      expect(inverse.task, task);
      expect(inverse.project, project);
      expect(inverse.area, isNull);
      expect(inverse.heading, isNull);
    });

    test(
      'lifecycle events invert to whatever restores the prior pair',
      () async {
        final open = await store.createTask(title: 'open');
        final done = await store.createTask(title: 'done');
        await store.completeTask(done);
        final dropped = await store.createTask(title: 'dropped');
        await store.cancelTask(dropped);
        final before = store.projection;
        final doneAt = before.task(done)!.completedAt;
        final droppedAt = before.task(dropped)!.cancelledAt;

        expect(
          invertEvent(TaskCompleted(open), before, created: fakeId),
          isA<TaskReopened>(),
        );
        final backToDone = invertEvent(
          TaskReopened(done),
          before,
          created: fakeId,
        ) as TaskCompleted;
        expect(backToDone.at, doneAt);
        final backToDropped = invertEvent(
          TaskCompleted(dropped),
          before,
          created: fakeId,
        ) as TaskCancelled;
        expect(backToDropped.at, droppedAt);
        final stillDone = invertEvent(
          TaskCancelled(done),
          before,
          created: fakeId,
        ) as TaskCompleted;
        expect(stillDone.at, doneAt);
      },
    );

    test('delete and restore invert state-aware, staying total', () async {
      final task = await store.createTask(title: 'x');
      final live = store.projection;
      expect(
        invertEvent(TaskDeleted(task), live, created: fakeId),
        isA<TaskRestored>(),
      );
      // Degenerate mutations invert to state-preserving events, so one
      // undo press never silently skips to an older mutation.
      expect(
        invertEvent(TaskRestored(task), live, created: fakeId),
        isA<TaskRestored>(),
      );
      await store.deleteTask(task);
      final trashed = store.projection;
      expect(
        invertEvent(TaskDeleted(task), trashed, created: fakeId),
        isA<TaskDeleted>(),
      );
      expect(
        invertEvent(TaskRestored(task), trashed, created: fakeId),
        isA<TaskDeleted>(),
      );
    });

    test('a checklist set inverts to the prior items', () async {
      const items = [ChecklistItem(title: 'flour')];
      final task = await store.createTask(title: 'bake', checklist: items);
      final inverse = invertEvent(
        TaskChecklistSet(task, const []),
        store.projection,
        created: fakeId,
      ) as TaskChecklistSet;
      expect(inverse.items, items);
    });

    test('container events invert like task events', () async {
      final area = await store.createArea(title: 'Home');
      final project = await store.createProject(title: 'P', area: area);
      final heading = await store.createHeading(project: project, title: 'H');
      final parent = await store.createTag(title: 'outer');
      final tag = await store.createTag(title: 'inner', parent: parent);
      final before = store.projection;

      expect(
        invertEvent(AreaCreated(title: 'x'), before, created: fakeId),
        isA<AreaDeleted>(),
      );
      final areaBack = invertEvent(
        AreaEdited(area, title: const Patch('Casa')),
        before,
        created: fakeId,
      ) as AreaEdited;
      expect(areaBack.title!.value, 'Home');
      final projectBack = invertEvent(
        ProjectEdited(project, area: const Patch(null)),
        before,
        created: fakeId,
      ) as ProjectEdited;
      expect(projectBack.area!.value, area);
      final headingBack = invertEvent(
        HeadingEdited(heading, title: const Patch('Prep')),
        before,
        created: fakeId,
      ) as HeadingEdited;
      expect(headingBack.title!.value, 'H');
      final tagBack = invertEvent(
        TagEdited(tag, parent: const Patch(null)),
        before,
        created: fakeId,
      ) as TagEdited;
      expect(tagBack.parent!.value, parent);
      expect(
        invertEvent(ProjectDeleted(project), before, created: fakeId),
        isA<ProjectRestored>(),
      );
      expect(
        invertEvent(TagRestored(tag), before, created: fakeId),
        isA<TagRestored>(),
      );
    });

    group('every mutable edit field round-trips through its inverse', () {
      const model = ModelRef(provider: 'anthropic', id: 'claude-fable-5');

      test('task.edit: title, notes, when, deadline, tags', () async {
        final t1 = await store.createTag(title: 't1');
        final t2 = await store.createTag(title: 't2');
        final id = await store.createTask(
          title: 'old',
          notes: 'old notes',
          when: TaskWhen.someday,
          deadline: const CalendarDate(2026, 9, 1),
          tags: [t1],
        );
        final prior = store.projection.task(id)!;
        await store.editTask(
          id,
          title: const Patch('new'),
          notes: const Patch('new notes'),
          when: const Patch(TaskWhen.date(CalendarDate(2026, 9, 2))),
          deadline: const Patch(null),
          tags: Patch([t2]),
          by: const Attribution.assistant(model),
        );
        final edited = store.projection.task(id)!;
        expect(edited.title, 'new');
        expect(edited.tags, [t2]);
        await store.undo();
        final back = store.projection.task(id)!;
        expect(back.title, prior.title);
        expect(back.notes, prior.notes);
        expect(back.when, prior.when);
        expect(back.deadline, prior.deadline);
        expect(back.tags, prior.tags);
        expect(back.modifiedAt.isAfter(prior.modifiedAt), isTrue);
      });

      test('project.edit: title, notes, area, when, deadline, tags', () async {
        final a1 = await store.createArea(title: 'a1');
        final a2 = await store.createArea(title: 'a2');
        final t1 = await store.createTag(title: 't1');
        final id = await store.createProject(
          title: 'old',
          notes: 'old notes',
          area: a1,
          when: TaskWhen.date(const CalendarDate(2026, 9, 1)),
          deadline: const CalendarDate(2026, 9, 3),
          tags: [t1],
        );
        final prior = store.projection.projects[id]!;
        await store.editProject(
          id,
          title: const Patch('new'),
          notes: const Patch(''),
          area: Patch(a2),
          when: const Patch(TaskWhen.none),
          deadline: const Patch(null),
          tags: const Patch([]),
        );
        expect(store.projection.projects[id]!.area, a2);
        await store.undo();
        final back = store.projection.projects[id]!;
        expect(back.title, prior.title);
        expect(back.notes, prior.notes);
        expect(back.area, prior.area);
        expect(back.when, prior.when);
        expect(back.deadline, prior.deadline);
        expect(back.tags, prior.tags);
      });

      test('tag.edit: title, parent', () async {
        final p1 = await store.createTag(title: 'p1');
        final id = await store.createTag(title: 'old', parent: p1);
        final prior = store.projection.tags[id]!;
        await store.editTag(
          id,
          title: const Patch('new'),
          parent: const Patch(null),
        );
        expect(store.projection.tags[id]!.parent, isNull);
        await store.undo();
        final back = store.projection.tags[id]!;
        expect(back.title, prior.title);
        expect(back.parent, prior.parent);
      });

      test('area.edit and heading.edit: title', () async {
        final area = await store.createArea(title: 'Home');
        final project = await store.createProject(title: 'P');
        final heading = await store.createHeading(project: project, title: 'H');
        await store.editArea(area, title: const Patch('Casa'));
        await store.editHeading(heading, title: const Patch('Prep'));
        expect(store.projection.areas[area]!.title, 'Casa');
        expect(store.projection.headings[heading]!.title, 'Prep');
        await store.undo();
        await store.undo();
        expect(store.projection.areas[area]!.title, 'Home');
        expect(store.projection.headings[heading]!.title, 'H');
      });
    });

    test('all 33 types invert to the type the model doc promises', () async {
      final area = await store.createArea(title: 'A');
      final project = await store.createProject(title: 'P');
      final heading = await store.createHeading(project: project, title: 'H');
      final tag = await store.createTag(title: 'T');
      final task = await store.createTask(title: 'x');
      final before = store.projection;
      final cases = <String, (TaskEvent, Type)>{
        TaskEventTypes.taskCreate: (TaskCreated(title: 'y'), TaskDeleted),
        TaskEventTypes.taskEdit: (
          TaskEdited(task, title: const Patch('y')),
          TaskEdited,
        ),
        TaskEventTypes.taskMove: (TaskMoved(task, project: project), TaskMoved),
        TaskEventTypes.taskReorder: (
          TaskReordered(task, list: TaskList.today, after: null),
          TaskReordered,
        ),
        TaskEventTypes.taskComplete: (TaskCompleted(task), TaskReopened),
        TaskEventTypes.taskCancel: (TaskCancelled(task), TaskReopened),
        TaskEventTypes.taskReopen: (TaskReopened(task), TaskReopened),
        TaskEventTypes.taskDelete: (TaskDeleted(task), TaskRestored),
        TaskEventTypes.taskRestore: (TaskRestored(task), TaskRestored),
        TaskEventTypes.taskChecklist: (
          TaskChecklistSet(task, const []),
          TaskChecklistSet,
        ),
        TaskEventTypes.areaCreate: (AreaCreated(title: 'y'), AreaDeleted),
        TaskEventTypes.areaEdit: (
          AreaEdited(area, title: const Patch('y')),
          AreaEdited,
        ),
        TaskEventTypes.areaReorder: (
          AreaReordered(area, after: null),
          AreaReordered,
        ),
        TaskEventTypes.areaArchive: (AreaArchived(area), AreaUnarchived),
        TaskEventTypes.areaUnarchive: (AreaUnarchived(area), AreaUnarchived),
        TaskEventTypes.areaDelete: (AreaDeleted(area), AreaRestored),
        TaskEventTypes.areaRestore: (AreaRestored(area), AreaRestored),
        TaskEventTypes.projectCreate: (
          ProjectCreated(title: 'y'),
          ProjectDeleted,
        ),
        TaskEventTypes.projectEdit: (
          ProjectEdited(project, title: const Patch('y')),
          ProjectEdited,
        ),
        TaskEventTypes.projectReorder: (
          ProjectReordered(project, after: null),
          ProjectReordered,
        ),
        TaskEventTypes.projectArchive: (
          ProjectArchived(project),
          ProjectUnarchived,
        ),
        TaskEventTypes.projectUnarchive: (
          ProjectUnarchived(project),
          ProjectUnarchived,
        ),
        TaskEventTypes.projectDelete: (
          ProjectDeleted(project),
          ProjectRestored,
        ),
        TaskEventTypes.projectRestore: (
          ProjectRestored(project),
          ProjectRestored,
        ),
        TaskEventTypes.headingCreate: (
          HeadingCreated(project: project, title: 'y'),
          HeadingDeleted,
        ),
        TaskEventTypes.headingEdit: (
          HeadingEdited(heading, title: const Patch('y')),
          HeadingEdited,
        ),
        TaskEventTypes.headingReorder: (
          HeadingReordered(heading, after: null),
          HeadingReordered,
        ),
        TaskEventTypes.headingDelete: (
          HeadingDeleted(heading),
          HeadingRestored,
        ),
        TaskEventTypes.headingRestore: (
          HeadingRestored(heading),
          HeadingRestored,
        ),
        TaskEventTypes.tagCreate: (TagCreated(title: 'y'), TagDeleted),
        TaskEventTypes.tagEdit: (
          TagEdited(tag, title: const Patch('y')),
          TagEdited,
        ),
        TaskEventTypes.tagDelete: (TagDeleted(tag), TagRestored),
        TaskEventTypes.tagRestore: (TagRestored(tag), TagRestored),
      };
      expect(cases.keys, unorderedEquals(TaskEventTypes.all));
      for (final MapEntry(key: type, value: (event, inverse))
          in cases.entries) {
        expect(event.type, type);
        expect(
          invertEvent(event, before, created: fakeId).runtimeType,
          inverse,
          reason: type,
        );
      }
    });

    test('an unknown subject throws StateError', () {
      expect(
        () => invertEvent(
          TaskDeleted(fakeId),
          TaskProjection.empty,
          created: fakeId,
        ),
        throwsStateError,
      );
    });
  });

  group('TaskStore.splitTask (#35)', () {
    test('a split is N creates and a delete, one undo entry', () async {
      final project = await store.createProject(title: 'P');
      final heading = await store.createHeading(project: project, title: 'H');
      final tag = await store.createTag(title: 'errand');
      final original = await store.createTask(
        title: 'Big chore',
        notes: 'the notes',
        when: const TaskWhen.date(CalendarDate(2026, 8, 30)),
        deadline: const CalendarDate(2026, 9, 5),
        project: project,
        heading: heading,
        tags: [tag],
        checklist: [const ChecklistItem(title: 'step')],
      );
      final before = store.undoDepth;
      final parts = await store.splitTask(original, [' First ', 'Second']);
      expect(parts, hasLength(2));
      expect(store.undoDepth, before + 1, reason: 'one entry for the split');

      final first = store.projection.task(parts[0])!;
      final second = store.projection.task(parts[1])!;
      expect(first.title, 'First');
      expect(first.notes, 'the notes');
      expect(first.checklist.single.title, 'step');
      expect(second.title, 'Second');
      expect(second.notes, '');
      expect(second.checklist, isEmpty);
      for (final part in [first, second]) {
        expect(part.project, project);
        expect(part.heading, heading);
        expect(part.tags, [tag]);
        expect(part.when, const TaskWhen.date(CalendarDate(2026, 8, 30)));
        expect(part.deadline, const CalendarDate(2026, 9, 5));
        expect(part.status, TaskStatus.open);
      }
      expect(store.projection.task(original)!.deletedAt, isNotNull);
      final types = [
        for (final line in logLines()) (jsonDecode(line) as Map)['type'],
      ];
      expect(types.sublist(types.length - 3), [
        'task.create',
        'task.create',
        'task.delete',
      ]);
    });

    test('one undo restores the original and trashes the parts', () async {
      final original = await store.createTask(title: 'Big chore', notes: 'k');
      final parts = await store.splitTask(original, ['a', 'b']);
      expect(store.undoDepth, 2, reason: 'the create and the split');
      await store.undo();
      final restored = store.projection.task(original)!;
      expect(restored.deletedAt, isNull);
      expect(restored.notes, 'k');
      for (final part in parts) {
        expect(store.projection.task(part)!.deletedAt, isNotNull);
      }
      expect(store.undoDepth, 1);
    });

    test('refuses blank or lone parts and a non-open original', () async {
      final id = await store.createTask(title: 'x');
      await expectLater(store.splitTask(id, ['only']), throwsArgumentError);
      await expectLater(store.splitTask(id, ['a', ' ']), throwsArgumentError);
      await store.completeTask(id);
      await expectLater(store.splitTask(id, ['a', 'b']), throwsStateError);
      expect(
        store.undoDepth,
        2,
        reason: 'refusals record nothing beyond the create and complete',
      );
    });

    test('an assistant split attributes and refs every line', () async {
      final proposal = BlobRef.sha256OfBytes([9]);
      final accept = BlobRef.sha256OfBytes([10]);
      final id = await store.createTask(title: 'x');
      await store.splitTask(
        id,
        ['a', 'b'],
        by: Attribution.assistant(
          const ModelRef(provider: 'fake', id: 'f'),
          refs: [proposal, accept],
        ),
      );
      final lines = logLines().sublist(1);
      expect(lines, hasLength(3));
      for (final line in lines) {
        final map = jsonDecode(line) as Map;
        expect(map['actor'], 'assistant');
        expect(map['model'], isNotNull);
        expect(
          (map['refs'] as List),
          containsAll([proposal.toString(), accept.toString()]),
        );
      }
    });

    test('a system split is the barrier, recording no entry', () async {
      final id = await store.createTask(title: 'x');
      expect(store.canUndo, isTrue);
      await store.splitTask(id, ['a', 'b'], by: const Attribution.system());
      expect(store.canUndo, isFalse);
    });
  });

  group('the proposal fingerprint guard (#35)', () {
    test('editTask ifModifiedAt refuses a changed task atomically', () async {
      final id = await store.createTask(title: 'x');
      final stamp = store.projection.task(id)!.modifiedAt;
      await store.editTask(id, title: const Patch('y'));
      final before = logLines().length;
      await expectLater(
        store.editTask(
          id,
          when: const Patch(TaskWhen.someday),
          ifModifiedAt: stamp,
        ),
        throwsStateError,
      );
      expect(logLines().length, before, reason: 'nothing was appended');
      expect(store.projection.task(id)!.when, TaskWhen.none);
      // The current fingerprint passes.
      await store.editTask(
        id,
        when: const Patch(TaskWhen.someday),
        ifModifiedAt: store.projection.task(id)!.modifiedAt,
      );
      expect(store.projection.task(id)!.when, TaskWhen.someday);
    });

    test('splitTask ifModifiedAt refuses a changed original', () async {
      final id = await store.createTask(title: 'x');
      final stamp = store.projection.task(id)!.modifiedAt;
      await store.editTask(id, title: const Patch('y'));
      final before = logLines().length;
      await expectLater(
        store.splitTask(id, ['a', 'b'], ifModifiedAt: stamp),
        throwsStateError,
      );
      expect(logLines().length, before, reason: 'nothing was appended');
    });
  });

  group('TaskStore.undo', () {
    const today = CalendarDate(2026, 8, 24);

    test('a fresh store has nothing to undo', () async {
      expect(store.canUndo, isFalse);
      expect(store.undoDepth, 0);
      expect(await store.undo(), isNull);
      expect(logLines(), isEmpty);
    });

    test('undoing a create soft-deletes into the Trash', () async {
      final id = await store.quickCapture('Buy oat milk', today: today);
      expect(store.canUndo, isTrue);
      final undone = await store.undo();
      expect(undone, isNotNull);
      expect(store.projection.list(TaskList.inbox, today: today), isEmpty);
      expect(store.projection.trash().single.id, id);
      expect(logLines(), hasLength(2));
      final check = await archive.verify();
      expect(check.count, 2);
    });

    test('undoing an edit restores the prior values only', () async {
      final id = await store.createTask(title: 'old', notes: 'keep me');
      await store.editTask(id, title: const Patch('new'));
      await store.undo();
      final task = store.projection.task(id)!;
      expect(task.title, 'old');
      expect(task.notes, 'keep me');
    });

    test(
      'a schedule edit and its undo leave the deadline alone (#98)',
      () async {
        const deadline = CalendarDate(2026, 9, 1);
        final id = await store.createTask(title: 'x', deadline: deadline);
        await store.editTask(id, when: const Patch(TaskWhen.someday));
        expect(store.projection.task(id)!.when, TaskWhen.someday);
        expect(store.projection.task(id)!.deadline, deadline);
        expect(logLines().last, isNot(contains('deadline')));
        await store.undo();
        expect(store.projection.task(id)!.when, TaskWhen.none);
        expect(store.projection.task(id)!.deadline, deadline);
      },
    );

    test('undoing a move restores the prior placement', () async {
      final project = await store.createProject(title: 'P');
      final id = await store.createTask(title: 'x', project: project);
      await store.moveTask(id);
      expect(store.projection.task(id)!.project, isNull);
      await store.undo();
      expect(store.projection.task(id)!.project, project);
    });

    test('undoing moves of completed and deleted tasks stays valid', () async {
      Future<void> exercise({required bool deleted}) async {
        final project = await store.createProject(title: 'P');
        await store.createTask(title: 'anchor', project: project);
        final id = await store.createTask(title: 'hidden', project: project);
        if (deleted) {
          await store.deleteTask(id);
        } else {
          await store.completeTask(id);
        }
        final priorOrder = store.projection.structuralOrder;

        await store.moveTask(id);
        expect(store.projection.task(id)!.project, isNull);
        await store.undo();

        expect(store.projection.task(id)!.project, project);
        expect(store.projection.structuralOrder, priorOrder);
      }

      await exercise(deleted: false);
      await exercise(deleted: true);
    });

    test('undoing structural reorder restores its prior predecessor', () async {
      const today = CalendarDate(2026, 8, 24);
      await store.createTask(title: 'a');
      await store.createTask(title: 'b');
      final c = await store.createTask(title: 'c');
      await store.reorderTask(c, after: null);
      expect(
        store.projection.list(TaskList.inbox, today: today).map((t) => t.title),
        ['c', 'a', 'b'],
      );
      await store.undo();
      expect(
        store.projection.list(TaskList.inbox, today: today).map((t) => t.title),
        ['a', 'b', 'c'],
      );
    });

    test('undoing atomic move restores placement and order', () async {
      const today = CalendarDate(2026, 8, 24);
      await store.createTask(title: 'a');
      await store.createTask(title: 'b');
      final c = await store.createTask(title: 'c');
      final project = await store.createProject(title: 'P');
      final filed = await store.createTask(title: 'filed', project: project);
      await store.moveTask(c, project: project, after: Patch(filed));
      await store.undo();
      expect(store.projection.task(c)!.project, isNull);
      expect(
        store.projection.list(TaskList.inbox, today: today).map((t) => t.title),
        ['a', 'b', 'c'],
      );
    });

    test('undoing Today reorder does not change structural order', () async {
      const today = CalendarDate(2026, 8, 24);
      final a = await store.createTask(
        title: 'a',
        when: const TaskWhen.date(today),
      );
      final b = await store.createTask(
        title: 'b',
        when: const TaskWhen.date(today),
      );
      final c = await store.createTask(
        title: 'c',
        when: const TaskWhen.date(today),
      );
      await store.reorderToday(c, after: null);
      expect(
        store.projection.list(TaskList.today, today: today).map((t) => t.title),
        ['c', 'a', 'b'],
      );
      await store.undo();
      expect(
        store.projection.list(TaskList.today, today: today).map((t) => t.title),
        ['a', 'b', 'c'],
      );
      expect(store.projection.structuralOrder, [a, b, c]);
    });

    test('undoing lifecycle changes restores the exact instants', () async {
      final id = await store.createTask(title: 'x');
      await store.completeTask(id);
      final completedAt = store.projection.task(id)!.completedAt;
      await store.cancelTask(id);
      await store.undo();
      final task = store.projection.task(id)!;
      expect(task.status, TaskStatus.completed);
      expect(task.completedAt, completedAt);
      await store.undo();
      expect(store.projection.task(id)!.status, TaskStatus.open);
    });

    test('undoing delete and restore round-trips', () async {
      final id = await store.createTask(title: 'x');
      await store.deleteTask(id);
      await store.undo();
      expect(store.projection.task(id)!.deletedAt, isNull);
      await store.restoreTask(id); // degenerate: already restored
      await store.undo();
      expect(store.projection.task(id)!.deletedAt, isNull);
    });

    test('undoing a checklist set restores the prior items', () async {
      const items = [ChecklistItem(title: 'flour')];
      final id = await store.createTask(title: 'bake', checklist: items);
      await store.setChecklist(id, const []);
      await store.undo();
      expect(store.projection.task(id)!.checklist, items);
    });

    test('container commands undo too', () async {
      final area = await store.createArea(title: 'Home');
      await store.editArea(area, title: const Patch('Casa'));
      await store.undo();
      expect(store.projection.areas[area]!.title, 'Home');
      await store.undo();
      expect(store.projection.areas[area]!.deletedAt, isNotNull);
    });

    test('a session unwinds in reverse, one undo per mutation', () async {
      final id = await store.createTask(title: 'first');
      await store.editTask(id, title: const Patch('second'));
      await store.completeTask(id);
      expect(store.undoDepth, 3);

      await store.undo();
      expect(store.projection.task(id)!.status, TaskStatus.open);
      await store.undo();
      expect(store.projection.task(id)!.title, 'first');
      await store.undo();
      expect(store.projection.trash().single.id, id);
      expect(store.canUndo, isFalse);
      expect(await store.undo(), isNull);
      expect(logLines(), hasLength(6));
    });

    test('undo records no inverse of its own — no redo', () async {
      await store.createTask(title: 'x');
      expect(store.undoDepth, 1);
      await store.undo();
      expect(store.undoDepth, 0);
    });

    test('the undo line refs the event it reverses', () async {
      final id = await store.createTask(title: 'x');
      await store.editTask(id, title: const Patch('y'));
      final editLine = logLines().last;
      final editId = BlobRef.sha256OfBytes(utf8.encode(editLine));
      await store.undo();
      final undoJson = jsonDecode(logLines().last) as Map<String, Object?>;
      final refs = (undoJson['refs'] as List).cast<String>();
      expect(refs, contains(editId.toString()));
      expect(refs, contains(id.toString()));
    });

    test('a create-undo dedupes the subject ref', () async {
      final id = await store.createTask(title: 'x');
      await store.undo();
      final undoJson = jsonDecode(logLines().last) as Map<String, Object?>;
      final refs = (undoJson['refs'] as List).cast<String>();
      expect(refs, [id.toString()]);
    });

    test('undo attribution is the caller´s', () async {
      const model = ModelRef(provider: 'anthropic', id: 'claude-fable-5');
      final id = await store.createTask(title: 'x');
      await store.completeTask(id);
      await store.undo(by: const Attribution.assistant(model));
      final undoJson = jsonDecode(logLines().last) as Map<String, Object?>;
      expect(undoJson['actor'], 'assistant');
      expect((undoJson['model'] as Map<String, Object?>)['id'], isNotNull);
    });

    test('an assistant cannot undo a container mutation', () async {
      const model = ModelRef(provider: 'anthropic', id: 'claude-fable-5');
      await store.createArea(title: 'Home');
      await expectLater(
        store.undo(by: const Attribution.assistant(model)),
        throwsArgumentError,
      );
      expect(store.canUndo, isTrue);
      expect(logLines(), hasLength(1));
      await store.undo();
      expect(store.projection.areas.values.single.deletedAt, isNotNull);
    });

    test('a refused inverse keeps its stack entry', () async {
      final project = await store.createProject(title: 'P');
      final id = await store.createTask(title: 'x', project: project);
      await store.moveTask(id);

      final other = await TaskStore.open(archive, source: 'sai/app');
      await other.deleteProject(project);
      other.dispose();
      await store.reload();

      await expectLater(store.undo(), throwsA(isA<TaskProjectionError>()));
      expect(store.canUndo, isTrue);
      expect(logLines(), hasLength(4));
    });

    test('the stack survives a reload', () async {
      final id = await store.createTask(title: 'x');
      await store.reload();
      expect(store.canUndo, isTrue);
      await store.undo();
      expect(store.projection.trash().single.id, id);
    });

    test('a disposed store refuses undo', () async {
      await store.createTask(title: 'x');
      store.dispose();
      await expectLater(store.undo(), throwsStateError);
      store = await TaskStore.open(archive, source: 'sai/tui');
    });

    test('a synchronous changes listener sees the popped stack', () async {
      final seen = <(bool, int)>[];
      store.changes.listen((_) => seen.add((store.canUndo, store.undoDepth)));
      await store.createTask(title: 'x');
      expect(seen.last, (true, 1));
      await store.undo();
      expect(seen.last, (false, 0));
    });

    test('a failed undo still leaves listeners consistent', () async {
      final project = await store.createProject(title: 'P');
      final id = await store.createTask(title: 'x', project: project);
      await store.moveTask(id);
      final other = await TaskStore.open(archive, source: 'sai/app');
      await other.deleteProject(project);
      other.dispose();
      await store.reload();

      final seen = <(bool, int)>[];
      store.changes.listen((_) => seen.add((store.canUndo, store.undoDepth)));
      await expectLater(store.undo(), throwsA(isA<TaskProjectionError>()));
      // The refused inverse appended nothing, notified nothing, and the
      // stack still holds every entry.
      expect(seen, isEmpty);
      expect(store.undoDepth, 3);
    });

    test('undo interleaves with commands without losing events', () async {
      await Future.wait([
        store.createTask(title: 'a'),
        store.createTask(title: 'b'),
        store.undo(),
      ]);
      expect(logLines(), hasLength(3));
      expect(store.projection.trash().single.title, 'b');
      expect(store.projection.tasks.values.map((t) => t.title).toSet(), {
        'a',
        'b',
      });
      expect((await archive.verify()).count, 3);
    });
  });
  group('the undo barrier and bound', () {
    final fakeId = BlobRef.sha256OfBytes([1]);
    const model = ModelRef(provider: 'anthropic', id: 'claude-fable-5');
    const today = CalendarDate(2026, 8, 24);

    test(
      'the stack keeps the newest 100 entries, oldest dropped first',
      () async {
        for (var i = 0; i <= TaskStore.undoLimit; i++) {
          await store.quickCapture('task $i', today: today);
        }
        expect(store.undoDepth, TaskStore.undoLimit);
        while (store.canUndo) {
          await store.undo();
        }
        final left = store.projection.tasks.values.where(
          (t) => t.deletedAt == null,
        );
        expect(left.single.title, 'task 0');
        expect(store.undoDepth, 0);
      },
    );

    test('user and assistant mutations are undoable', () async {
      final id = await store.createTask(title: 'x');
      await store.editTask(
        id,
        title: const Patch('y'),
        by: const Attribution.assistant(model),
      );
      expect(store.undoDepth, 2);
      await store.undo();
      expect(store.projection.task(id)!.title, 'x');
    });

    test(
      'a committed system mutation clears the stack and adds nothing',
      () async {
        final id = await store.createTask(title: 'x');
        await store.editTask(id, title: const Patch('y'));
        expect(store.undoDepth, 2);
        await store.createTask(
          title: 'imported',
          by: const Attribution.system(),
        );
        expect(store.undoDepth, 0);
        expect(store.canUndo, isFalse);
        expect(logLines(), hasLength(3));
      },
    );

    test('a rejected system mutation changes nothing', () async {
      final id = await store.createTask(title: 'x');
      final before = store.projection;
      await expectLater(
        store.deleteTask(fakeId, by: const Attribution.system()),
        throwsA(isA<TaskProjectionError>()),
      );
      expect(store.undoDepth, 1);
      expect(identical(store.projection, before), isTrue);
      expect(logLines(), hasLength(1));
      await store.undo();
      expect(store.projection.task(id)!.deletedAt, isNotNull);
    });

    test(
      'a system mutation another writer appended clears on reload',
      () async {
        await store.createTask(title: 'x');
        final other = await TaskStore.open(archive, source: 'sai/app');
        await other.createTask(
          title: 'imported',
          by: const Attribution.system(),
        );
        other.dispose();
        expect(store.undoDepth, 1);
        await store.reload();
        expect(store.undoDepth, 0);
      },
    );

    test(
      'a reload without a new system task mutation keeps the stack',
      () async {
        await store.createTask(title: 'x');
        final other = await TaskStore.open(archive, source: 'sai/app');
        await other.createTask(title: 'theirs');
        other.dispose();
        await archive.append(
          EventDraft(
            type: EventTypes.chatMessage,
            actor: Actor.system,
            source: 'sai/tui',
            payload: {'text': 'hello'},
          ),
        );
        await store.reload();
        expect(store.undoDepth, 1);
        await store.reload();
        expect(store.undoDepth, 1);
      },
    );

    test('a remote system line before a local commit still clears', () async {
      await store.createTask(title: 'x');
      final other = await TaskStore.open(archive, source: 'sai/app');
      await other.createTask(title: 'imported', by: const Attribution.system());
      other.dispose();
      // The local commit lands after the import line and advances the
      // projection past it without ever having seen it.
      await store.createTask(title: 'y');
      expect(store.undoDepth, 2);
      await store.reload();
      expect(store.undoDepth, 0);
      expect(store.projection.tasks, hasLength(3));
    });

    test('a reload the reducer refuses keeps the stack', () async {
      final project = await store.createProject(title: 'P');
      final stale = await TaskStore.open(archive, source: 'sai/app');
      await store.deleteProject(project);
      // Valid against the stale projection, invalid in log order.
      await stale.createTask(
        title: 'imported',
        project: project,
        by: const Attribution.system(),
      );
      stale.dispose();
      expect(store.undoDepth, 2);
      await expectLater(store.reload(), throwsA(isA<TaskProjectionError>()));
      expect(store.undoDepth, 2);
      expect(store.projection.tasks, isEmpty);
      await store.undo();
      expect(store.projection.projects[project]!.deletedAt, isNull);
    });

    test('a system-attributed undo is a barrier too', () async {
      await store.createTask(title: 'x');
      await store.createTask(title: 'y');
      await store.undo(by: const Attribution.system());
      expect(store.projection.trash(), hasLength(1));
      expect(store.canUndo, isFalse);
    });
  });

  group('container order and archive (#74)', () {
    const today = CalendarDate(2026, 8, 24);

    test('a container reorder inverts to the prior predecessor', () async {
      final a = await store.createArea(title: 'a');
      final b = await store.createArea(title: 'b');
      final c = await store.createArea(title: 'c');
      final p1 = await store.createProject(title: 'p1', area: a);
      final p2 = await store.createProject(title: 'p2', area: a);
      final h1 = await store.createHeading(project: p1, title: 'h1');
      final h2 = await store.createHeading(project: p1, title: 'h2');
      await store.reorderArea(c, after: null);
      await store.reorderProject(p2, after: null);
      await store.reorderHeading(h2, after: null);
      expect(store.projection.areaOrder, [c, a, b]);
      expect(store.projection.projectOrder, [p2, p1]);
      expect(store.projection.headingOrder, [h2, h1]);
      await store.undo();
      await store.undo();
      await store.undo();
      expect(store.projection.areaOrder, [a, b, c]);
      expect(store.projection.projectOrder, [p1, p2]);
      expect(store.projection.headingOrder, [h1, h2]);
      expect(store.undoDepth, 7, reason: 'the creates remain');
    });

    test('archive and unarchive invert state-aware, staying total', () async {
      final area = await store.createArea(title: 'A');
      await store.archiveArea(area);
      await store.archiveArea(area);
      await store.unarchiveArea(area);
      await store.unarchiveArea(area);
      final before = store.projection;
      expect(
        invertEvent(AreaArchived(area), before, created: area),
        isA<AreaUnarchived>(),
      );
      await store.undo(); // unarchive-of-live → unarchive
      expect(store.projection.areas[area]!.archivedAt, isNull);
      await store.undo(); // unarchive → archive
      expect(store.projection.areas[area]!.archivedAt, isNotNull);
      await store.undo(); // archive-again → archive
      expect(store.projection.areas[area]!.archivedAt, isNotNull);
      await store.undo(); // archive → unarchive
      expect(store.projection.areas[area]!.archivedAt, isNull);
    });

    test('undoing an archive brings the project and its tasks back', () async {
      final project = await store.createProject(title: 'P');
      final task = await store.createTask(title: 't', project: project);
      await store.archiveProject(project);
      expect(store.projection.list(TaskList.anytime, today: today), isEmpty);
      expect(sidebarModel(store.projection, today: today).projects, isEmpty);
      await store.undo();
      expect(
        store.projection.list(TaskList.anytime, today: today).map((t) => t.id),
        [task],
      );
      expect(
        sidebarModel(store.projection, today: today).projects.single.title,
        'P',
      );
    });

    test(
      'undoing an area change restores the area at the end of that group',
      () async {
        final home = await store.createArea(title: 'Home');
        final work = await store.createArea(title: 'Work');
        final p1 = await store.createProject(title: 'p1', area: home);
        final p2 = await store.createProject(title: 'p2', area: home);
        await store.editProject(p1, area: Patch(work));
        expect(store.projection.projectOrder, [p2, p1]);
        await store.undo();
        expect(store.projection.projects[p1]!.area, home);
        expect(store.projection.projectOrder, [p2, p1]);
      },
    );
  });
}
