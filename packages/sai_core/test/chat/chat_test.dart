import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

/// A fake that answers with what it was shown: `role:text` per message,
/// so a test can prove the list reached (or did not reach) the model.
String echo(LlmRequest r) =>
    r.messages.map((m) => '${m.role.name}:${m.text}').join(' | ');

void main() {
  late Directory tmp;
  late FakeLlmProvider fake;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_chat_test');
    fake = FakeLlmProvider(script: echo);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<ProviderContainer> make({
    List<Override> overrides = const [],
    List<LlmProvider> extraLlms = const [],
  }) async {
    final container = ProviderContainer.test(
      overrides: [
        archiveRootProvider.overrideWithValue(Directory('${tmp.path}/archive')),
        settingsFileProvider.overrideWithValue(
          File('${tmp.path}/settings.json'),
        ),
        eventSourceProvider.overrideWithValue('sai/test'),
        secretStoreProvider.overrideWithValue(InMemorySecretStore()),
        builtinLlmsProvider.overrideWithValue([
          () => fake,
          for (final llm in extraLlms) () => llm,
        ]),
        todayProvider.overrideWith(_FixedToday.new),
        ...overrides,
      ],
    );
    await container.read(tasksProvider.future);
    final store = container.read(tasksProvider.notifier).store;
    await store.createTask(
      title: 'Call mom',
      when: const TaskWhen.date(CalendarDate(2026, 8, 25)),
    );
    await store.createTask(
      title: 'Ring dentist',
      when: const TaskWhen.date(CalendarDate(2026, 8, 26)),
    );
    container.read(settingsProvider.notifier).selectLlm('fake');
    return container;
  }

  List<Map<String, Object?>> lines() {
    final dir = Directory('${tmp.path}/archive/events');
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return [
      for (final file in files)
        for (final line in file.readAsStringSync().split('\n'))
          if (line.isNotEmpty) jsonDecode(line) as Map<String, Object?>,
    ];
  }

  test(
    'a turn is recorded around its call and the model saw the list',
    () async {
      final container = await make();
      final chat = container.read(chatProvider.notifier);
      await chat.send('  what is due today?  ');

      final state = container.read(chatProvider);
      expect(state.busy, isFalse);
      expect(state.error, isNull);
      expect(state.turns.map((t) => t.role), [
        ChatRole.user,
        ChatRole.assistant,
      ]);
      expect(state.turns[0].text, 'what is due today?');
      expect(state.turns[0].event, isNotNull);
      final answer = state.turns[1];
      expect(answer.text, contains('system:$assistantProfile'));
      expect(answer.text, contains('Call mom @today'));
      expect(answer.text, contains('Ring dentist @tomorrow'));
      expect(answer.text, endsWith('user:what is due today?'));
      expect(answer.finish, LlmFinish.stop);
      expect(answer.failed, isFalse);
      expect(answer.tasksWithheld, isFalse);

      final log = lines().where((l) => l['type'] != 'task.create').toList();
      expect(log.map((l) => l['type']), [
        'chat.message',
        'provider.request',
        'provider.response',
        'provider.usage',
        'chat.message',
      ]);
      expect(log[0]['actor'], 'user');
      expect(log[0]['payload'], {'text': 'what is due today?'});
      // The fake is local, so the model saw the whole catalog (#105).
      expect(answer.provenance, TaskProvenance.catalog);
      final request = log[1]['payload']! as Map<String, Object?>;
      final sentMessages = request['messages']! as List;
      expect(sentMessages[1], {
        'role': 'system',
        'text': taskCatalog(
          container.read(tasksProvider).value!,
          today: const CalendarDate(2026, 8, 25),
        ),
      });
      expect(request['context_hash'], startsWith('sha256-'));
      expect(request['max_tokens'], defaultContextBudget.replyReserve);
      final said = log[4];
      expect(said['actor'], 'assistant');
      expect(said['model'], {
        'provider': 'fake',
        'id': 'fake-1',
        'version': 'fake-1',
        'request_id': 'fake-req-1',
      });
      expect(said['payload'], {'text': answer.text, 'finish': 'stop'});
      expect(answer.event, isNotNull);
      // The assistant line names its response line (raw index: two
      // task.create lines, then user, request, response).
      final responseId = Event.decodeLine(_rawLines(tmp)[4]).deriveId();
      expect(said['refs'], [responseId.toString()]);
    },
  );

  test('what the budget cut is on the answer for the client', () async {
    // On the compact path — a cloud provider with sharing on — so the
    // Upcoming cut still exists to be shown.
    final cloudy = FakeLlmProvider(
      id: 'cloudy',
      privacy: LlmPrivacy.cloud,
      script: echo,
    );
    var budget = defaultContextBudget;
    final container = await make(
      extraLlms: [cloudy],
      overrides: [chatBudgetProvider.overrideWith((ref) => budget)],
    );
    final settings = container.read(settingsProvider.notifier);
    settings.selectLlm('cloudy');
    settings.setShareTasksWithCloud(true);
    // A window that fits the profile, the draft and Today, but not the
    // Upcoming day.
    final chat = container.read(chatProvider.notifier);
    final projection = container.read(tasksProvider).value!;
    final fits =
        estimateTokens(assistantProfile) +
        estimateTokens('go') +
        estimateTokens(
          taskContextFor(
            projection,
            const CalendarDate(2026, 8, 25),
            upcomingDays: 0,
          ),
        );
    budget = ContextBudget(maxTokens: fits + 100, replyReserve: 100);
    await chat.send('go');
    final answer = container.read(chatProvider).turns.last;
    expect(answer.dropped, ['upcoming:2026-08-26']);
    expect(
      AssembledContext.cutNote(answer.dropped),
      'context cut: upcoming:2026-08-26',
    );
    expect(answer.text, isNot(contains('Ring dentist')));
  });

  test('an oversized catalog turn writes no event at all', () async {
    final container = await make(
      overrides: [
        chatBudgetProvider.overrideWith(
          (ref) => const ContextBudget(maxTokens: 1000000, replyReserve: 4096),
        ),
      ],
    );
    final store = container.read(tasksProvider.notifier).store;
    // Escape-heavy notes: the token estimate fits the roomy window, but
    // the JSON-encoded request crosses the recordable cap — and there is
    // nothing left to cut, so the send refuses before the user's
    // chat.message is written (#105).
    await store.createTask(title: 'Huge', notes: '"' * 400000);
    final chat = container.read(chatProvider.notifier);
    final before = lines().length;
    final accepted = await chat.send('what do I have?');
    expect(accepted, isFalse);
    expect(container.read(chatProvider).error, contains('once recorded'));
    expect(container.read(chatProvider).turns, isEmpty);
    expect(lines().length, before, reason: 'no orphan chat.message');
  });

  test('the conversation carries forward', () async {
    final container = await make();
    final chat = container.read(chatProvider.notifier);
    await chat.send('first');
    await chat.send('second');
    final last = container.read(chatProvider).turns.last.text;
    expect(last, contains('user:first'));
    expect(last, contains('assistant:system:'));
    expect(last, endsWith('user:second'));
    expect(container.read(chatProvider).turns, hasLength(4));
  });

  test('the answer streams into the state before it is done', () async {
    fake = FakeLlmProvider(
      script: (_) => 'alpha beta gamma delta',
      delta: const Duration(milliseconds: 10),
    );
    final container = await make();
    final seen = <String>[];
    container.listen(chatProvider, (_, next) {
      if (next.streaming != null) seen.add(next.streaming!);
    });
    await container.read(chatProvider.notifier).send('go');
    expect(seen, contains('alpha '));
    expect(seen, contains('alpha beta '));
    expect(seen.last, 'alpha beta gamma delta');
    expect(container.read(chatProvider).streaming, isNull);
  });

  test('cancel keeps the partial answer, marked cancelled', () async {
    fake = FakeLlmProvider(
      script: (_) => List.filled(50, 'x').join(' '),
      delta: const Duration(milliseconds: 20),
    );
    final container = await make();
    final chat = container.read(chatProvider.notifier);
    final sending = chat.send('go');
    // Cancel only once a delta has landed — condition-polled, so a slow
    // runner cannot cancel before the stream began (CI flaked at a
    // fixed 70ms).
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!(container.read(chatProvider).streaming?.isNotEmpty ?? false)) {
      if (DateTime.now().isAfter(deadline)) fail('no delta arrived');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(container.read(chatProvider).busy, isTrue);
    chat.cancel();
    await sending;
    final state = container.read(chatProvider);
    expect(state.busy, isFalse);
    final answer = state.turns.last;
    expect(answer.finish, LlmFinish.cancelled);
    expect(answer.text, isNotEmpty);
    expect(answer.text.length, lessThan(99));
    final said = lines().last;
    expect(said['type'], 'chat.message');
    expect(said['payload'], {'text': answer.text, 'finish': 'cancelled'});
  });

  test('a failed call is a failed turn with no assistant line', () async {
    fake = FakeLlmProvider(
      failWith: const LlmFailure(
        LlmFailureKind.unreachable,
        'nothing answered at the endpoint',
        endpoint: 'http://localhost:1',
      ),
    );
    final container = await make();
    await container.read(chatProvider.notifier).send('go');
    final state = container.read(chatProvider);
    expect(state.busy, isFalse);
    final answer = state.turns.last;
    expect(answer.failed, isTrue);
    expect(answer.failure!.kind, LlmFailureKind.unreachable);
    expect(answer.event, isNull);
    final types = lines()
        .map((l) => l['type'])
        .where((t) => t != 'task.create');
    expect(types, [
      'chat.message',
      'provider.request',
      'provider.failure',
      'provider.usage',
    ]);
  });

  test(
    'reasoning streams apart from the answer and lands on the turn',
    () async {
      fake = FakeLlmProvider(
        script: (_) => 'ready.',
        reasoning: (_) => 'let me think',
        delta: const Duration(milliseconds: 5),
      );
      final container = await make();
      container.read(settingsProvider.notifier).setReasoning(true);
      final thoughts = <String>[];
      final answers = <String>[];
      container.listen(chatProvider, (_, next) {
        if (next.reasoning != null) thoughts.add(next.reasoning!);
        if (next.streaming != null && next.streaming!.isNotEmpty) {
          answers.add(next.streaming!);
        }
      });
      await container.read(chatProvider.notifier).send('go');
      expect(thoughts, contains('let '));
      expect(thoughts.last, 'let me think');
      expect(answers.last, 'ready.');
      final turn = container.read(chatProvider).turns.last;
      expect(turn.text, 'ready.');
      expect(turn.reasoning, 'let me think');
      expect(container.read(chatProvider).reasoning, isNull);
      expect(
        lines().singleWhere((l) => l['type'] == 'provider.request')['payload'],
        isNot(contains('reasoning_effort')),
      );
    },
  );

  test(
    'with reasoning off the request says so and the fake stays quiet',
    () async {
      fake = FakeLlmProvider(
        script: (_) => 'ready.',
        reasoning: (_) => 'let me think',
      );
      final container = await make();
      expect(container.read(reasoningProvider), isFalse);
      await container.read(chatProvider.notifier).send('go');
      final turn = container.read(chatProvider).turns.last;
      expect(turn.text, 'ready.');
      expect(turn.reasoning, isNull);
      expect(
        lines().singleWhere((l) => l['type'] == 'provider.request')['payload'],
        containsPair('reasoning_effort', 'none'),
      );
    },
  );

  test('Stop before the call exists ends the turn with nothing sent', () async {
    fake = FakeLlmProvider(script: (_) => 'never');
    final container = await make();
    final chat = container.read(chatProvider.notifier);
    final sending = chat.send('go');
    expect(container.read(chatProvider).busy, isTrue);
    chat.cancel();
    expect(await sending, isFalse);
    final state = container.read(chatProvider);
    expect(state.busy, isFalse);
    expect(fake.requests, 0);
    expect(lines().where((l) => l['type'] == 'provider.request'), isEmpty);
    // A later send works as usual.
    expect(await chat.send('now'), isTrue);
    expect(fake.requests, 1);
  });

  test('a refusal raised during a turn ends with the turn', () async {
    fake = FakeLlmProvider(
      script: (_) => 'a b c',
      delta: const Duration(milliseconds: 10),
    );
    final container = await make();
    final chat = container.read(chatProvider.notifier);
    final first = chat.send('one');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await chat.send('two');
    expect(container.read(chatProvider).error, chatBusyError);
    await first;
    expect(container.read(chatProvider).error, isNull);
  });

  test(
    'a disposed container mid-answer neither throws nor streams on',
    () async {
      fake = FakeLlmProvider(
        script: (_) => List.filled(50, 'x').join(' '),
        delta: const Duration(milliseconds: 10),
      );
      final container = await make();
      final chat = container.read(chatProvider.notifier);
      final sending = chat.send('go');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      container.dispose();
      // Settles quietly, whichever side of done the dispose landed on:
      // nothing throws into the zone from the dead notifier.
      await sending;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    },
  );

  test('history goes in pairs; an unanswered question stays out', () async {
    final flaky = FakeLlmProvider(
      id: 'flaky',
      failWith: const LlmFailure(LlmFailureKind.internal, 'boom'),
    );
    final roles = FakeLlmProvider(
      id: 'roles',
      script: (r) => r.messages.map((m) => m.role.name).join(','),
    );
    final container = await make(extraLlms: [flaky, roles]);
    final settings = container.read(settingsProvider.notifier);
    final chat = container.read(chatProvider.notifier);
    settings.selectLlm('flaky');
    await chat.send('first');
    expect(container.read(chatProvider).turns.last.failed, isTrue);
    settings.selectLlm('roles');
    await chat.send('second');
    // The failed pair is gone as a whole: no two user lines in a row.
    expect(container.read(chatProvider).turns.last.text, 'system,system,user');
    await chat.send('third');
    expect(
      container.read(chatProvider).turns.last.text,
      'system,system,user,assistant,user',
    );
  });

  group('falling through the order (#62)', () {
    /// A provider that names a key nothing holds, so the order passes it
    /// over without asking any endpoint.
    ProviderConfig keyless(String id) =>
        ProviderConfig(id: id, kind: 'fake', credential: 'provider:$id');

    test('the answer comes from the next entry, and says what it passed '
        'over', () async {
      final container = await make();
      final settings = container.read(settingsProvider.notifier);
      settings.upsertProvider(keyless('keyed'));
      settings.setLlmOrder(['keyed', 'fake']);
      expect(await container.read(chatProvider.notifier).send('due?'), isTrue);
      final answer = container.read(chatProvider).turns.last;
      // A local provider answered, so the shape is the catalog (#105).
      expect(answer.provenance, TaskProvenance.catalog);
      expect(answer.text, contains('Call mom'));
      final log = lines().where((l) => l['type'] != 'task.create').toList();
      expect(log.map((l) => l['type']), [
        'chat.message',
        'policy.fallback',
        'provider.request',
        'provider.response',
        'provider.usage',
        'chat.message',
      ]);
      final fallback = log[1];
      expect(fallback['payload'], {
        'first': 'keyed',
        'chosen': 'fake',
        'skipped': [
          {'provider': 'keyed', 'reason': 'no_key', 'detail': 'no key'},
        ],
      });
      expect(fallback['model'], {'provider': 'fake', 'id': 'fake-1'});
      // The request names it; the linkage itself is pinned in
      // `recorder_test`.
      expect(log[2]['refs'], hasLength(1));
    });

    test('the shape follows the provider that answered, not the first '
        'choice', () async {
      final cloudy = FakeLlmProvider(
        id: 'cloudy',
        privacy: LlmPrivacy.cloud,
        script: echo,
      );
      final container = await make(extraLlms: [cloudy]);
      final settings = container.read(settingsProvider.notifier);
      settings.setShareTasksWithCloud(true);
      settings.upsertProvider(keyless('keyed'));
      settings.setLlmOrder(['keyed', 'cloudy']);
      expect(container.read(activeLlmProvider)?.id, 'cloudy');
      await container.read(chatProvider.notifier).send('due?');
      final answer = container.read(chatProvider).turns.last;
      // The cloud provider answered, so it saw the compact lists only.
      expect(answer.provenance, TaskProvenance.compact);
      expect(answer.text, isNot(contains('TASK CATALOG')));
      expect(answer.text, contains('Call mom @today'));
      final types = lines()
          .map((l) => l['type'])
          .where((t) => t != 'task.create');
      expect(types, [
        'chat.message',
        'policy.fallback',
        'policy.decision',
        'provider.request',
        'provider.response',
        'provider.usage',
        'chat.message',
      ]);
    });

    test('nothing eligible refuses the send and writes nothing', () async {
      final container = await make();
      final settings = container.read(settingsProvider.notifier);
      settings.upsertProvider(keyless('keyed'));
      settings.upsertProvider(
        ProviderConfig(id: 'cloudy', kind: 'fake', privacy: LlmPrivacy.cloud),
      );
      settings.setLlmOrder(['keyed', 'cloudy', 'gone']);
      expect(await container.read(chatProvider.notifier).send('due?'), isFalse);
      expect(
        container.read(chatProvider).error,
        'no provider can answer — keyed no key, cloudy cloud not allowed, '
        'gone not available',
      );
      expect(container.read(chatProvider).turns, isEmpty);
      expect(lines().where((l) => l['type'] != 'task.create'), isEmpty);
    });
  });

  group('with a cloud provider', () {
    setUp(() {
      fake = FakeLlmProvider(
        id: 'cloudy',
        privacy: LlmPrivacy.cloud,
        script: echo,
      );
    });

    test('sharing off passes it over and nothing is sent or written', () async {
      final container = await make();
      container.read(settingsProvider.notifier).selectLlm('cloudy');
      // The order ends at the last local one (#62); with nothing behind
      // it, the send is refused before a word is written.
      expect(await container.read(chatProvider.notifier).send('due?'), isFalse);
      final state = container.read(chatProvider);
      expect(state.turns, isEmpty);
      expect(state.error, 'no provider can answer — cloudy cloud not allowed');
      final types = lines()
          .map((l) => l['type'])
          .where((t) => t != 'task.create');
      expect(types, isEmpty);
    });

    test(
      'turning sharing on lets it answer, from the same conversation',
      () async {
        final container = await make();
        final settings = container.read(settingsProvider.notifier);
        settings.selectLlm('cloudy');
        final chat = container.read(chatProvider.notifier);
        expect(await chat.send('due?'), isFalse);
        settings.setShareTasksWithCloud(true);
        final next = chat.send('and now?');
        // Busy already, before any await — and not claiming a withheld list.
        expect(container.read(chatProvider).busy, isTrue);
        expect(container.read(chatProvider).tasksWithheld, isFalse);
        await next;
        final answer = container.read(chatProvider).turns.last;
        expect(answer.tasksWithheld, isFalse);
        expect(answer.text, contains('Call mom @today'));
      },
    );

    test('an answer that saw the catalog stays out of a cloud call', () async {
      // Turn 1 on the local fake quotes the catalog; turn 2 goes to the
      // cloud fake — sharing on, since nothing else may — and must not
      // carry that answer (#105).
      final local = FakeLlmProvider(id: 'homely', script: echo);
      final container = await make(extraLlms: [local]);
      final settings = container.read(settingsProvider.notifier);
      settings.selectLlm('homely');
      final chat = container.read(chatProvider.notifier);
      await chat.send('due?');
      expect(
        container.read(chatProvider).turns.last.provenance,
        TaskProvenance.catalog,
      );
      expect(
        container.read(chatProvider).turns.last.text,
        contains('Call mom'),
      );
      settings.setShareTasksWithCloud(true);
      settings.selectLlm('cloudy');
      await chat.send('and then?');
      final answer = container.read(chatProvider).turns.last;
      expect(answer.provenance, TaskProvenance.compact);
      // The catalog answer's question goes with it — the governed
      // request keeps its roles alternating.
      expect(answer.text, isNot(contains('user:due?')));
      expect(answer.text, contains('user:and then?'));
      expect(answer.text, isNot(contains('TASK CATALOG')));
    });

    test('sharing on sends it', () async {
      final container = await make();
      final settings = container.read(settingsProvider.notifier);
      settings.selectLlm('cloudy');
      settings.setShareTasksWithCloud(true);
      await container.read(chatProvider.notifier).send('due?');
      final answer = container.read(chatProvider).turns.last;
      expect(answer.tasksWithheld, isFalse);
      expect(answer.text, contains('Call mom @today'));
    });
  });

  group('the propose lane (#35)', () {
    Future<void> until(bool Function() ready) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!ready()) {
        if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('an explicit request records, validates, fills the lane', () async {
      fake = FakeLlmProvider();
      final container = await make();
      final chat = container.read(chatProvider.notifier);
      expect(await chat.propose('   '), isTrue);

      final state = container.read(chatProvider);
      expect(state.busy, isFalse);
      expect(state.phase, ChatPhase.idle);
      expect(state.turns.map((t) => t.role), [
        ChatRole.user,
        ChatRole.assistant,
      ]);
      expect(state.turns[0].text, defaultProposalRequest);
      expect(state.turns[0].proposed, isTrue);
      expect(state.turns[1].text, isEmpty);
      expect(state.turns[1].proposal, isA<ProposalMade>());
      expect(turnNotes(state.turns[1]), ['proposed 2 changes']);

      final views = container.read(suggestionViewsProvider);
      expect(views, hasLength(2));
      expect(views[0].item.headline, 'Move to Someday');
      expect(views[0].item.targetTitle, 'Call mom');
      expect(views.any((v) => v.stale), isFalse);

      final log = lines().where((l) => l['type'] != 'task.create').toList();
      expect(log.map((l) => l['type']), [
        'chat.message',
        'provider.request',
        'provider.response',
        'provider.usage',
        'proposal.made',
      ]);
      expect(log[0]['payload'], {
        'text': defaultProposalRequest,
        'mode': 'propose',
      });
      final payload = log[1]['payload'] as Map;
      expect(payload['response_format'], isNotNull);
      final messages = (payload['messages'] as List).cast<Map>();
      expect(messages[1]['text'], contains('- [t1] Call mom @today'));
      expect(
        messages.last['text'],
        contains('Request: $defaultProposalRequest'),
      );
      final made = log[4];
      expect(made['actor'], 'assistant');
      expect(made['refs'], hasLength(2));
    });

    test('accepting applies through the store as the assistant', () async {
      fake = FakeLlmProvider();
      final container = await make();
      await container.read(chatProvider.notifier).propose('tidy up');
      expect(
        await container.read(proposalsProvider.notifier).accept(0),
        isNull,
      );
      final store = container.read(tasksProvider.notifier).store;
      final mom = store.projection.tasks.values.firstWhere(
        (t) => t.title == 'Call mom',
      );
      expect(mom.when, TaskWhen.someday);
      final edit = lines().lastWhere((l) => l['type'] == 'task.edit');
      expect(edit['actor'], 'assistant');
      expect(store.canUndo, isTrue);
    });

    test('bad output is a failed proposal turn, the lane empty', () async {
      fake = FakeLlmProvider(script: (_) => 'not json');
      final container = await make();
      await container.read(chatProvider.notifier).propose('x');
      final turn = container.read(chatProvider).turns[1];
      expect(turn.proposal, isA<ProposalRefused>());
      expect(turnNotes(turn), ['proposal failed: not JSON']);
      expect(container.read(suggestionViewsProvider), isEmpty);
      final types = lines().map((l) => l['type']).toList();
      expect(types, contains('proposal.refused'));
      expect(types, isNot(contains('proposal.made')));
    });

    test('a cloud provider is refused before anything is written', () async {
      final container = await make(
        extraLlms: [FakeLlmProvider(id: 'cloudy', privacy: LlmPrivacy.cloud)],
      );
      final settings = container.read(settingsProvider.notifier);
      settings.selectLlm('cloudy');
      final chat = container.read(chatProvider.notifier);
      // While sharing is off the order does not reach it at all (#62).
      expect(await chat.propose('x'), isFalse);
      expect(
        container.read(chatProvider).error,
        'no provider can answer — cloudy cloud not allowed',
      );
      // With sharing on it answers chat, but never a proposal.
      settings.setShareTasksWithCloud(true);
      expect(await chat.propose('x'), isFalse);
      expect(container.read(chatProvider).error, proposalsNeedLocal);
      expect(lines().where((l) => l['type'] == 'chat.message'), isEmpty);
    });

    test('a marker-ended answer strips, records and proposes', () async {
      fake = FakeLlmProvider(
        script: (r) => r.responseSchema != null
            ? fakeProposal(r)
            : 'Do less.\n$proposeMarker',
      );
      final container = await make();
      await container.read(chatProvider.notifier).send('what should change?');

      final state = container.read(chatProvider);
      expect(state.busy, isFalse);
      final answer = state.turns[1];
      expect(answer.text, 'Do less.');
      expect(answer.proposal, isA<ProposalMade>());
      expect(container.read(suggestionViewsProvider), hasLength(2));

      final log = lines().where((l) => l['type'] != 'task.create').toList();
      expect(log.map((l) => l['type']), [
        'chat.message',
        'provider.request',
        'provider.response',
        'provider.usage',
        'chat.message',
        'provider.request',
        'provider.response',
        'provider.usage',
        'proposal.made',
      ]);
      // The wire record keeps the marker; the conversation line is
      // what the person read, flagged.
      expect((log[2]['payload'] as Map)['text'], endsWith(proposeMarker));
      final said = log[4]['payload'] as Map;
      expect(said['text'], 'Do less.');
      expect(said['proposes'], true);
      final followup = ((log[5]['payload'] as Map)['messages'] as List)
          .cast<Map>();
      expect(followup.last['text'], contains(autoProposalRequest));
      expect(followup.map((m) => m['text']), contains('Do less.'));
      expect(log[8]['refs'], hasLength(2));
    });

    test('the streaming state never shows a partial marker', () async {
      final container = await make(extraLlms: [_Drip('Ok.\n$proposeMarker')]);
      container.read(settingsProvider.notifier).selectLlm('drip');
      final seen = <String>[];
      container.listen(chatProvider, (_, next) {
        if (next.streaming case final text?) seen.add(text);
      });
      await container.read(chatProvider.notifier).send('q');
      expect(seen.where((t) => t.contains('<sai')), isEmpty);
      expect(container.read(chatProvider).turns[1].text, 'Ok.');
    });

    test('Esc during the follow-up cancels it, keeps the answer', () async {
      fake = FakeLlmProvider(
        script: (r) => r.responseSchema != null
            ? fakeProposal(r)
            : 'Hold on.\n$proposeMarker',
        delta: const Duration(milliseconds: 15),
      );
      final container = await make();
      final chat = container.read(chatProvider.notifier);
      final done = chat.send('q');
      await until(
        () => container.read(chatProvider).phase == ChatPhase.proposing,
      );
      chat.cancel();
      await done;
      final turn = container.read(chatProvider).turns[1];
      expect(turn.text, 'Hold on.');
      expect(turn.proposal, isA<ProposalRefused>());
      expect(turnNotes(turn), ['proposal cancelled']);
      expect(container.read(suggestionViewsProvider), isEmpty);
      expect(lines().map((l) => l['type']), isNot(contains('proposal.made')));
    });

    test('a cloud answer that asks to propose is refused flat', () async {
      final container = await make(
        extraLlms: [
          FakeLlmProvider(
            id: 'cloudy',
            privacy: LlmPrivacy.cloud,
            script: (_) => 'Try less.\n$proposeMarker',
          ),
        ],
      );
      final settings = container.read(settingsProvider.notifier);
      settings.selectLlm('cloudy');
      settings.setShareTasksWithCloud(true);
      await container.read(chatProvider.notifier).send('ideas?');
      final turn = container.read(chatProvider).turns[1];
      expect(turn.text, 'Try less.');
      expect(
        turn.proposal,
        isA<ProposalRefused>().having(
          (p) => p.reason,
          'reason',
          proposalsNeedLocal,
        ),
      );
      final types = lines().map((l) => l['type']).toList();
      expect(
        types.where((t) => t == 'provider.request'),
        hasLength(1),
        reason: 'no follow-up call to the cloud',
      );
      expect(types.where((t) => '$t'.startsWith('proposal.')), isEmpty);
    });

    test('an oversized explicit proposal writes nothing at all', () async {
      final container = await make(
        overrides: [
          chatBudgetProvider.overrideWith(
            (ref) =>
                const ContextBudget(maxTokens: 1000000, replyReserve: 4096),
          ),
        ],
      );
      final store = container.read(tasksProvider.notifier).store;
      await store.createTask(title: 'Huge', notes: '"' * 400000);
      final before = lines().length;
      final chat = container.read(chatProvider.notifier);
      expect(await chat.propose('tidy'), isFalse);
      expect(container.read(chatProvider).error, contains('once recorded'));
      expect(container.read(chatProvider).turns, isEmpty);
      expect(container.read(chatProvider).busy, isFalse);
      expect(lines().length, before, reason: 'no orphan chat.message');
    });

    test('a schema-valid but absurd handle refuses, never wedges', () async {
      fake = FakeLlmProvider(
        script: (_) => jsonEncode({
          'suggestions': [
            {
              'kind': 'schedule',
              'task': 't999999999999999999999999999999',
              'when': 'someday',
              'deadline': '',
              'parts': <String>[],
              'reason': 'huge',
            },
          ],
          'note': '',
        }),
      );
      final container = await make();
      await container.read(chatProvider.notifier).propose('x');
      final state = container.read(chatProvider);
      expect(state.busy, isFalse, reason: 'the chat must not wedge');
      expect(
        state.turns[1].proposal,
        isA<ProposalRefused>().having(
          (p) => p.reason,
          'reason',
          contains('unknown handle'),
        ),
      );
      expect(lines().map((l) => l['type']), contains('proposal.refused'));
    });

    test('proposal turns stay out of later history', () async {
      fake = FakeLlmProvider(
        script: (r) => r.responseSchema != null ? fakeProposal(r) : echo(r),
      );
      final container = await make();
      final chat = container.read(chatProvider.notifier);
      await chat.propose('tidy up');
      await chat.send('and now?');
      final answer = container.read(chatProvider).turns.last.text;
      expect(answer, isNot(contains('Request:')));
      expect(answer, isNot(contains('suggestions')));
      expect(answer, endsWith('user:and now?'));
    });
  });

  group('refuses', () {
    test('a second send while one runs', () async {
      fake = FakeLlmProvider(
        script: (_) => 'a b c',
        delta: const Duration(milliseconds: 30),
      );
      final container = await make();
      final chat = container.read(chatProvider.notifier);
      final first = chat.send('one');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await chat.send('two');
      expect(container.read(chatProvider).error, chatBusyError);
      await first;
      expect(container.read(chatProvider).turns, hasLength(2));
      chat.clearError();
      expect(container.read(chatProvider).error, isNull);
    });

    test('a second send in the same tick, before any await', () async {
      // A terminal can deliver one Enter twice; the second must not race
      // the first to the recorder (it did: two user lines, one call).
      fake = FakeLlmProvider(
        script: (_) => 'a b c',
        delta: const Duration(milliseconds: 10),
      );
      final container = await make();
      final chat = container.read(chatProvider.notifier);
      final first = chat.send('one');
      final second = chat.send('one');
      expect(container.read(chatProvider).busy, isTrue);
      expect(container.read(chatProvider).error, chatBusyError);
      await Future.wait([first, second]);
      expect(container.read(chatProvider).turns, hasLength(2));
      final types = lines()
          .map((l) => l['type'])
          .where((t) => t != 'task.create');
      expect(types.where((t) => t == 'provider.request'), hasLength(1));
      expect(types.where((t) => t == 'chat.message'), hasLength(2));
    });

    test('without a provider', () async {
      final container = await make();
      container.read(settingsProvider.notifier).selectLlm(null);
      await container.read(chatProvider.notifier).send('hi');
      expect(container.read(chatProvider).error, noProviderStatus);
      expect(container.read(chatProvider).turns, isEmpty);
    });

    test('a blank line silently', () async {
      final container = await make();
      await container.read(chatProvider.notifier).send('   ');
      expect(container.read(chatProvider).error, isNull);
      expect(container.read(chatProvider).turns, isEmpty);
    });
  });
}

List<String> _rawLines(Directory tmp) {
  final dir = Directory('${tmp.path}/archive/events');
  final files = dir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final file in files)
      for (final line in file.readAsStringSync().split('\n'))
        if (line.isNotEmpty) line,
  ];
}

class _FixedToday extends TodayNotifier {
  @override
  CalendarDate build() => const CalendarDate(2026, 8, 25);
}

/// Streams rune by rune, so a partial marker can be on screen between
/// deltas; answers a schema request with the fake's canned proposal.
final class _Drip implements LlmProvider {
  _Drip(this.reply);

  final String reply;

  @override
  String get id => 'drip';
  @override
  String get displayName => 'drip';
  @override
  LlmPrivacy get privacy => LlmPrivacy.local;
  @override
  String get defaultModel => 'drip-1';

  @override
  LlmCall start(LlmRequest request) {
    final controller = LlmCallController(
      model: const ModelRef(provider: 'drip', id: 'drip-1'),
    );
    controller.run(() async {
      final text = request.responseSchema != null
          ? fakeProposal(request)
          : reply;
      for (final rune in text.runes) {
        await Future<void>.delayed(Duration.zero);
        if (controller.isDone) return;
        controller.add(String.fromCharCode(rune));
      }
      controller.finish(
        LlmResult(
          text: controller.text,
          finish: LlmFinish.stop,
          model: controller.model,
        ),
      );
    });
    return controller.call;
  }

  @override
  void releaseIdle() {}

  @override
  Future<void> close() async {}
}
