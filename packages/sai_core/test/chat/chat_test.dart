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
      expect(answer.text, contains('system:$defaultProfile'));
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
    final container = await make(extraLlms: [cloudy]);
    final settings = container.read(settingsProvider.notifier);
    settings.selectLlm('cloudy');
    settings.setShareTasksWithCloud(true);
    // A window that fits the profile, the draft and Today, but not the
    // Upcoming day.
    final chat = container.read(chatProvider.notifier);
    final projection = container.read(tasksProvider).value!;
    final fits =
        estimateTokens(defaultProfile) +
        estimateTokens('go') +
        estimateTokens(
          taskContextFor(
            projection,
            const CalendarDate(2026, 8, 25),
            upcomingDays: 0,
          ),
        );
    chat.budget = ContextBudget(maxTokens: fits + 100, replyReserve: 100);
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
    final container = await make();
    final store = container.read(tasksProvider.notifier).store;
    // Escape-heavy notes: the token estimate fits the roomy window, but
    // the JSON-encoded request crosses the recordable cap — and there is
    // nothing left to cut, so the send refuses before the user's
    // chat.message is written (#105).
    await store.createTask(title: 'Huge', notes: '"' * 400000);
    final chat = container.read(chatProvider.notifier);
    chat.budget = const ContextBudget(maxTokens: 1000000, replyReserve: 4096);
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
    await Future<void>.delayed(const Duration(milliseconds: 70));
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
        isNot(containsPair('reasoning', false)),
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
        containsPair('reasoning', false),
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

  group('with a cloud provider', () {
    setUp(() {
      fake = FakeLlmProvider(
        id: 'cloudy',
        privacy: LlmPrivacy.cloud,
        script: echo,
      );
    });

    test('sharing off withholds the list and says so', () async {
      final container = await make();
      container.read(settingsProvider.notifier).selectLlm('cloudy');
      await container.read(chatProvider.notifier).send('due?');
      final state = container.read(chatProvider);
      final answer = state.turns.last;
      expect(answer.tasksWithheld, isTrue);
      expect(answer.text, isNot(contains('Call mom')));
      expect(answer.text, contains('system:$defaultProfile'));
      final types = lines()
          .map((l) => l['type'])
          .where((t) => t != 'task.create');
      expect(types.first, 'chat.message');
      expect(types.elementAt(1), 'policy.decision');
      expect(jsonEncode(lines()), isNot(contains('Call mom @today')));
    });

    test('the withheld flag does not leak into the next turn', () async {
      final container = await make();
      final settings = container.read(settingsProvider.notifier);
      settings.selectLlm('cloudy');
      final chat = container.read(chatProvider.notifier);
      await chat.send('due?');
      expect(container.read(chatProvider).tasksWithheld, isTrue);
      settings.setShareTasksWithCloud(true);
      final next = chat.send('and now?');
      // Busy already, before any await — and not claiming a withheld list.
      expect(container.read(chatProvider).busy, isTrue);
      expect(container.read(chatProvider).tasksWithheld, isFalse);
      await next;
      expect(container.read(chatProvider).turns.last.tasksWithheld, isFalse);
    });

    test('an answer that saw the list stays out of a withheld call', () async {
      // Turn 1 on the local fake quotes the list; turn 2 goes to the
      // cloud fake with sharing off and must not carry that answer.
      final local = FakeLlmProvider(id: 'homely', script: echo);
      final container = await make(extraLlms: [local]);
      final settings = container.read(settingsProvider.notifier);
      settings.selectLlm('homely');
      final chat = container.read(chatProvider.notifier);
      await chat.send('due?');
      expect(
        container.read(chatProvider).turns.last.provenance,
        isNot(TaskProvenance.none),
      );
      expect(
        container.read(chatProvider).turns.last.text,
        contains('Call mom'),
      );
      settings.selectLlm('cloudy');
      await chat.send('and then?');
      final answer = container.read(chatProvider).turns.last;
      expect(answer.tasksWithheld, isTrue);
      expect(answer.text, contains('user:due?'));
      expect(answer.text, contains('user:and then?'));
      expect(answer.text, isNot(contains('Call mom')));
      expect(
        jsonEncode(lines()).split('Call mom @today').length - 1,
        3,
        reason:
            'the first request, its response and its chat line — '
            'nothing of the second call',
      );
      // Sharing on covers the compact lists only: the first answer saw
      // the catalog, so it stays out of the history even now (#105) —
      // the withheld second answer, which saw nothing, may return.
      settings.setShareTasksWithCloud(true);
      await chat.send('again?');
      final again = container.read(chatProvider).turns.last.text;
      expect(again, contains('user:due?'));
      expect(again, isNot(contains('TASK CATALOG')));
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
