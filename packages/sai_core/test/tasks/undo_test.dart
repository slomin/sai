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

    test('undoing a move restores the prior placement', () async {
      final project = await store.createProject(title: 'P');
      final id = await store.createTask(title: 'x', project: project);
      await store.moveTask(id);
      expect(store.projection.task(id)!.project, isNull);
      await store.undo();
      expect(store.projection.task(id)!.project, project);
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
}
