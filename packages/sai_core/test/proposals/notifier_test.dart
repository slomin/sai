import 'dart:convert';
import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late ProviderContainer container;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_proposals_notifier');
    addTearDown(() => tmp.deleteSync(recursive: true));
    container = ProviderContainer.test(
      overrides: [
        archiveRootProvider.overrideWithValue(Directory('${tmp.path}/archive')),
        settingsFileProvider.overrideWithValue(
          File('${tmp.path}/settings.json'),
        ),
        eventSourceProvider.overrideWithValue('sai/test'),
        secretStoreProvider.overrideWithValue(InMemorySecretStore()),
      ],
    );
  });

  List<String> rawLines() {
    final dir = Directory('${tmp.path}/archive/events');
    if (!dir.existsSync()) return const [];
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return [
      for (final file in files)
        for (final line in file.readAsStringSync().split('\n'))
          if (line.isNotEmpty) line,
    ];
  }

  List<Map<String, Object?>> lines() => [
    for (final line in rawLines()) jsonDecode(line) as Map<String, Object?>,
  ];

  final madeId = BlobRef.sha256OfBytes(utf8.encode('made'));
  const model = ModelRef(provider: 'fake', id: 'fake-1');

  /// One open task and a one-item proposal targeting it.
  Future<(TaskStore, TaskId, Proposal)> offerOne({
    SuggestionKind kind = SuggestionKind.schedule,
    List<String> parts = const [],
  }) async {
    await container.read(tasksProvider.future);
    final store = container.read(tasksProvider.notifier).store;
    final id = await store.createTask(title: 'Buy milk');
    final task = store.projection.task(id)!;
    final proposal = Proposal(
      event: madeId,
      model: model,
      note: 'one idea',
      items: [
        Suggestion(
          index: 0,
          kind: kind,
          target: id,
          targetTitle: task.title,
          fingerprint: task.modifiedAt,
          when: kind == SuggestionKind.schedule ? TaskWhen.someday : null,
          deadline: null,
          parts: parts,
          reason: 'later',
        ),
      ],
    );
    container.read(proposalsProvider.notifier).offer(proposal);
    return (store, id, proposal);
  }

  test('accept records the verdict, then applies as the assistant', () async {
    final (store, id, proposal) = await offerOne();
    final notifier = container.read(proposalsProvider.notifier);
    expect(await notifier.accept(0), isNull);

    final log = lines();
    expect(log.map((l) => l['type']).toList().sublist(1), [
      'proposal.accept',
      'task.edit',
    ]);
    final accept = log[1];
    expect(accept['actor'], 'user');
    expect(accept['refs'], [madeId.toString()]);
    expect(accept['payload'], {'item': 0});
    final edit = log[2];
    expect(edit['actor'], 'assistant');
    expect(edit['model'], isNotNull);
    // The id of an event is the hash of its exact line bytes (ADR 0003).
    final acceptId = BlobRef.sha256OfBytes(utf8.encode(rawLines()[1]));
    expect(
      (edit['refs'] as List),
      containsAll([madeId.toString(), acceptId.toString()]),
    );

    expect(store.projection.task(id)!.when, TaskWhen.someday);
    expect(
      container.read(proposalsProvider).current!.items.single.status,
      SuggestionStatus.accepted,
    );
    final view = container.read(suggestionViewsProvider).single;
    expect(view.stale, isFalse, reason: 'a settled item is never stale');
    expect(store.canUndo, isTrue);
    await store.undo();
    expect(store.projection.task(id)!.when, TaskWhen.none);
  });

  test('reject records only the verdict', () async {
    final (store, id, _) = await offerOne();
    expect(await container.read(proposalsProvider.notifier).reject(0), isNull);
    expect(lines().last['type'], 'proposal.reject');
    expect(store.projection.task(id)!.when, TaskWhen.none);
    expect(
      container.read(proposalsProvider).current!.items.single.status,
      SuggestionStatus.rejected,
    );
  });

  test('a stale suggestion refuses before anything is written', () async {
    final (store, id, _) = await offerOne();
    await store.editTask(id, title: const Patch('Renamed'));
    expect(container.read(suggestionViewsProvider).single.stale, isTrue);
    expect(
      await container.read(proposalsProvider.notifier).accept(0),
      staleSuggestion,
    );
    expect(
      lines().map((l) => l['type']).where((t) => '$t'.startsWith('proposal.')),
      isEmpty,
    );
    expect(
      container.read(proposalsProvider).current!.items.single.status,
      SuggestionStatus.pending,
    );
  });

  test('a settled item refuses another verdict', () async {
    await offerOne();
    final notifier = container.read(proposalsProvider.notifier);
    await notifier.reject(0);
    expect(await notifier.accept(0), suggestionSettled);
    expect(await notifier.reject(0), suggestionSettled);
  });

  test('an out-of-range index is refused', () async {
    await offerOne();
    expect(
      await container.read(proposalsProvider.notifier).accept(3),
      'no such suggestion',
    );
  });

  test('an accepted split is one undo entry', () async {
    final (store, id, _) = await offerOne(
      kind: SuggestionKind.split,
      parts: ['first', 'second'],
    );
    final before = store.undoDepth;
    expect(await container.read(proposalsProvider.notifier).accept(0), isNull);
    expect(store.undoDepth, before + 1);
    expect(store.projection.task(id)!.deletedAt, isNotNull);
    await store.undo();
    expect(store.projection.task(id)!.deletedAt, isNull);
  });

  test('the store guard refuses a fingerprint gone stale mid-flight', () async {
    // The lane's pre-check can race a concurrent edit; the store's
    // ifModifiedAt guard is the atomic authority. Simulated by applying
    // with the old fingerprint after an edit landed.
    final (store, id, proposal) = await offerOne();
    await store.editTask(id, title: const Patch('Renamed'));
    await expectLater(
      applySuggestion(
        proposal.items.single,
        store: store,
        proposal: proposal,
        accept: BlobRef.sha256OfBytes(utf8.encode('accept')),
      ),
      throwsStateError,
    );
    expect(
      lines().where((l) => (l['type'] as String).startsWith('task.')).length,
      2,
      reason: 'the create and the rename; the assistant wrote nothing',
    );
  });

  test('a new proposal replaces the lane without writing', () async {
    final (_, id, first) = await offerOne();
    final replacement = Proposal(
      event: BlobRef.sha256OfBytes(utf8.encode('other')),
      model: model,
      note: 'newer',
      items: const [],
    );
    container.read(proposalsProvider.notifier).offer(replacement);
    expect(container.read(proposalsProvider).current!.note, 'newer');
    expect(container.read(suggestionViewsProvider), isEmpty);
    expect(
      lines().map((l) => l['type']).where((t) => '$t'.startsWith('proposal.')),
      isEmpty,
      reason: 'superseded pending items are not rejections',
    );
    expect(first.items.single.target, id);
  });
}
