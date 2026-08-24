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
    tmp = Directory.systemTemp.createTempSync('sai_task_store_test');
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

  test('an empty archive opens to an empty projection', () {
    expect(store.projection.tasks, isEmpty);
    expect(store.projection.eventCount, 0);
  });

  test('createTask appends exactly the minimal line', () async {
    final id = await store.createTask(title: 'x');
    final lines = logLines();
    expect(lines, hasLength(1));
    final json = jsonDecode(lines.single) as Map<String, Object?>;
    expect(json['type'], 'task.create');
    expect(json['actor'], 'user');
    expect(json['source'], 'sai/tui');
    expect(json['payload'], {'title': 'x'});
    expect(id, BlobRef.sha256OfBytes(utf8.encode(lines.single)));
    expect(store.projection.task(id)!.title, 'x');
    expect((await archive.verify()).count, 1);
  });

  test(
    'every command verb appends one event and updates the projection',
    () async {
      final area = await store.createArea(title: 'Home');
      final project = await store.createProject(title: 'Kitchen', area: area);
      final heading = await store.createHeading(
        project: project,
        title: 'Prep',
      );
      final tag = await store.createTag(title: 'errand');
      final task = await store.createTask(title: 'Buy milk', tags: [tag]);

      await store.editTask(task, title: const Patch('Buy oat milk'));
      expect(store.projection.task(task)!.title, 'Buy oat milk');

      await store.moveTask(task, project: project, heading: heading);
      expect(store.projection.task(task)!.heading, heading);

      await store.completeTask(task);
      expect(store.projection.task(task)!.status, TaskStatus.completed);
      await store.reopenTask(task);
      expect(store.projection.task(task)!.status, TaskStatus.open);
      await store.cancelTask(task);
      expect(store.projection.task(task)!.status, TaskStatus.cancelled);

      await store.setChecklist(task, [const ChecklistItem(title: 'oat')]);
      expect(store.projection.task(task)!.checklist, hasLength(1));

      await store.deleteTask(task);
      expect(store.projection.task(task)!.deletedAt, isNotNull);
      await store.restoreTask(task);
      expect(store.projection.task(task)!.deletedAt, isNull);

      await store.editArea(area, title: const Patch('House'));
      expect(store.projection.areas[area]!.title, 'House');
      await store.editProject(project, notes: const Patch('refit'));
      expect(store.projection.projects[project]!.notes, 'refit');
      await store.editHeading(heading, title: const Patch('Demolition'));
      expect(store.projection.headings[heading]!.title, 'Demolition');
      await store.editTag(tag, title: const Patch('errands'));
      expect(store.projection.tags[tag]!.title, 'errands');

      await store.deleteHeading(heading);
      expect(store.projection.headings[heading]!.deletedAt, isNotNull);
      await store.restoreHeading(heading);
      await store.deleteTag(tag);
      await store.restoreTag(tag);
      await store.deleteProject(project);
      await store.restoreProject(project);
      await store.deleteArea(area);
      await store.restoreArea(area);

      expect(logLines(), hasLength(25));
      expect(store.projection.eventCount, 25);
      final report = await archive.verify();
      expect(report.count, 25);
      expect(report.head, store.projection.lastEventId);
    },
  );

  test(
    'a second store on the same archive replays to the same state',
    () async {
      final project = await store.createProject(title: 'P');
      await store.createTask(title: 'a', project: project);
      await store.createTask(
        title: 'b',
        deadline: const CalendarDate(2026, 9, 1),
      );

      final second = await TaskStore.open(archive, source: 'sai/app');
      expect(second.projection.toJson(), store.projection.toJson());
      second.dispose();
    },
  );

  test('clearing a deadline writes a literal null', () async {
    final task = await store.createTask(
      title: 'x',
      deadline: const CalendarDate(2026, 9, 1),
    );
    await store.editTask(task, deadline: const Patch(null));
    expect(logLines().last, contains('"deadline":null'));
    expect(store.projection.task(task)!.deadline, isNull);
  });

  test('a command against an unknown id appends nothing', () async {
    final ghost = BlobRef.sha256OfBytes(utf8.encode('ghost'));
    await expectLater(
      store.editTask(ghost, title: const Patch('x')),
      throwsA(isA<TaskProjectionError>()),
    );
    await expectLater(
      store.moveTask(ghost, project: null),
      throwsA(isA<TaskProjectionError>()),
    );
    expect(logLines(), isEmpty);
    expect(store.projection.eventCount, 0);
  });

  test('interleaved chat events are replayed over, not tripped over', () async {
    final task = await store.createTask(title: 'x');
    await archive.append(
      EventDraft(
        type: EventTypes.chatMessage,
        actor: Actor.user,
        source: 'sai/tui',
        payload: {'text': 'hello'},
      ),
    );
    await store.reload();
    await store.completeTask(task);

    final second = await TaskStore.open(archive, source: 'sai/tui');
    expect(second.projection.toJson(), store.projection.toJson());
    expect(second.projection.eventCount, 3);
    second.dispose();
  });

  test('changes emits the new projection once per command', () async {
    final seen = <int>[];
    final sub = store.changes.listen((p) => seen.add(p.eventCount));
    final task = await store.createTask(title: 'x');
    // Delivery is synchronous: by the time a command's future completes,
    // every listener has seen the new projection.
    expect(seen, [1]);
    await store.completeTask(task);
    expect(seen, [1, 2]);
    await sub.cancel();
  });

  test('an assistant attribution carries the model and its refs', () async {
    final task = await store.createTask(title: 'x');
    const model = ModelRef(provider: 'anthropic', id: 'claude-fable-5');
    final proposal = BlobRef.sha256OfBytes(utf8.encode('proposal'));
    await store.completeTask(
      task,
      by: Attribution.assistant(model, refs: [proposal]),
    );
    final json = jsonDecode(logLines().last) as Map<String, Object?>;
    expect(json['actor'], 'assistant');
    expect((json['model'] as Map)['provider'], 'anthropic');
    expect(json['refs'], [task.toString(), proposal.toString()]);
  });

  test('reload picks up events appended behind the store', () async {
    final other = await TaskStore.open(archive, source: 'sai/app');
    await other.createTask(title: 'from the app');
    other.dispose();

    expect(store.projection.tasks, isEmpty);
    await store.reload();
    expect(store.projection.tasks.values.single.title, 'from the app');
  });

  test('a command after dispose throws and appends nothing', () async {
    store.dispose();
    await expectLater(store.createTask(title: 'x'), throwsA(isA<StateError>()));
    expect(logLines(), isEmpty);
  });

  test('a torn tail does not take the store down', () async {
    final task = await store.createTask(title: 'survives');
    final day = Directory('${tmp.path}/events')
        .listSync()
        .whereType<File>()
        .single;
    day.writeAsStringSync('{"torn', mode: FileMode.append, flush: true);

    final second = await TaskStore.open(archive, source: 'sai/tui');
    expect(second.projection.task(task)!.title, 'survives');
    expect(second.projection.eventCount, 1);
    second.dispose();

    await store.reload();
    expect(store.projection.eventCount, 1);
  });

  test('commands and reloads interleave without losing events', () async {
    await Future.wait([
      store.createTask(title: 'a'),
      store.createTask(title: 'b'),
      store.reload(),
      store.createTask(title: 'c'),
    ]);
    expect(logLines(), hasLength(3));
    expect(store.projection.eventCount, 3);
    expect(store.projection.tasks.values.map((t) => t.title).toSet(), {
      'a',
      'b',
      'c',
    });
  });
}
