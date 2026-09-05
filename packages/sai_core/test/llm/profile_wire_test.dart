/// The assistant profile (#14) is the first thing every model is told, on
/// every kind this build can talk to: the recorded `provider.request` and
/// the kind's own wire form must both carry it, byte for byte. The two
/// are different claims — the line says assembly put it first and the
/// privacy governor left it there; the wire says the kind's serializer
/// carried it, as a `system` message, a `developer` item or the thread's
/// `baseInstructions`.
///
/// The one recorded call that deliberately carries no profile is
/// `providerTestRequest` (`lib/src/llm/probe.dart`): the Providers page's
/// Test button, a neutral one-word prompt whose point is that the
/// endpoint answers at all. Nothing else that reaches the recorder goes
/// without it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/process_testing.dart';
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

import 'stub_server.dart';

/// A kind set up for one turn: its container, and how to read the profile
/// back off its own wire once the turn is over.
typedef _Ready = (ProviderContainer, Future<String> Function());

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('sai_profile_wire'));
  tearDown(() => tmp.deleteSync(recursive: true));

  List<Override> base({SecretStore? secrets}) => [
    archiveRootProvider.overrideWithValue(Directory('${tmp.path}/archive')),
    settingsFileProvider.overrideWithValue(File('${tmp.path}/settings.json')),
    eventSourceProvider.overrideWithValue('sai/test'),
    secretStoreProvider.overrideWithValue(secrets ?? InMemorySecretStore()),
    // Only the kind under test is installed, so the order cannot resolve
    // to anything else, and no built-in is probed.
    builtinLlmsProvider.overrideWithValue(const []),
    defaultLlmIdProvider.overrideWithValue(null),
    todayProvider.overrideWith(_FixedToday.new),
  ];

  List<Map<String, Object?>> requests() {
    final dir = Directory('${tmp.path}/archive/events');
    if (!dir.existsSync()) return const [];
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return [
      for (final file in files)
        for (final line in file.readAsStringSync().split('\n'))
          if (line.isNotEmpty)
            if (jsonDecode(line) case final Map<String, Object?> map
                when map['type'] == 'provider.request')
              map,
    ];
  }

  String recordedFirst() {
    final payload = requests().single['payload']! as Map<String, Object?>;
    final first = (payload['messages']! as List).first as Map<String, Object?>;
    return first['text']! as String;
  }

  /// The first chat-completions message the stub received.
  String chatFirst(StubServer stub) {
    final body = jsonDecode(stub.requests.single.body) as Map<String, Object?>;
    final first = (body['messages']! as List).first as Map<String, Object?>;
    expect(first['role'], 'system');
    return first['content']! as String;
  }

  final recipes = <String, Future<_Ready> Function()>{
    'fake': () async {
      final c = ProviderContainer.test(overrides: base());
      final settings = c.read(settingsProvider.notifier);
      settings.upsertProvider(ProviderConfig(id: 'faker', kind: 'fake'));
      settings.selectLlm('faker');
      // The fake answers in-process: there is no serializer between
      // LlmRecorder.start and FakeLlmProvider.start, so this kind's wire
      // is the recorded request. Read again anyway, so the coverage check
      // below is not satisfied by an empty recipe.
      return (c, () async => recordedFirst());
    },
    'openai_compatible': () async {
      final stub = await StubServer.start();
      addTearDown(stub.close);
      stub.routes['POST /v1/chat/completions'] = (req) =>
          StubServer.stream(req, ['ready.']);
      final c = ProviderContainer.test(overrides: base());
      final settings = c.read(settingsProvider.notifier);
      settings.upsertProvider(
        ProviderConfig(
          id: 'box',
          kind: 'openai_compatible',
          endpoint: stub.v1.toString(),
          defaultModel: 'qwen',
        ),
      );
      settings.selectLlm('box');
      return (c, () async => chatFirst(stub));
    },
    openRouterKind: () async {
      final secrets = InMemorySecretStore()
        ..write('provider:openrouter', 'not-a-real-key');
      final stub = await StubServer.start();
      addTearDown(stub.close);
      stub.routes['POST /v1/chat/completions'] = (req) =>
          StubServer.stream(req, ['ready.'], id: 'gen-1');
      final c = ProviderContainer.test(
        overrides: [
          ...base(secrets: secrets),
          openRouterEndpointProvider.overrideWithValue(stub.v1),
        ],
      );
      final settings = c.read(settingsProvider.notifier);
      settings.upsertProvider(
        ProviderConfig(
          id: 'openrouter',
          kind: openRouterKind,
          defaultModel: openRouterPresetModel,
          routing: 'deepinfra_fp8',
          credential: 'provider:openrouter',
        ),
      );
      // A cloud provider answers only while sharing is on (#62).
      settings.setShareTasksWithCloud(true);
      settings.selectLlm('openrouter');
      return (c, () async => chatFirst(stub));
    },
    openAiKind: () async {
      final secrets = InMemorySecretStore()
        ..write('provider:openai', 'not-a-real-key');
      final stub = await StubServer.start();
      addTearDown(stub.close);
      stub.routes['POST /v1/responses'] = (req) async {
        final r = StubServer.sse(req);
        StubServer.event(r, {
          'type': 'response.created',
          'response': {'id': 'resp_1', 'status': 'in_progress'},
        });
        StubServer.event(r, {
          'type': 'response.output_item.added',
          'output_index': 0,
          'item': {'type': 'message', 'id': 'msg_1', 'role': 'assistant'},
        });
        StubServer.event(r, {
          'type': 'response.output_text.delta',
          'item_id': 'msg_1',
          'output_index': 0,
          'content_index': 0,
          'delta': 'ready.',
        });
        StubServer.event(r, {
          'type': 'response.output_text.done',
          'text': 'ready.',
        });
        StubServer.event(r, {
          'type': 'response.completed',
          'response': {
            'id': 'resp_1',
            'object': 'response',
            'status': 'completed',
            'model': 'gpt-5.6-sol',
            'output': <Object?>[],
            'usage': {'input_tokens': 7, 'output_tokens': 1, 'total_tokens': 8},
          },
        });
        await r.close();
      };
      final c = ProviderContainer.test(
        overrides: [
          ...base(secrets: secrets),
          openAiEndpointProvider.overrideWithValue(stub.v1),
        ],
      );
      final settings = c.read(settingsProvider.notifier);
      settings.upsertProvider(
        ProviderConfig(
          id: 'openai',
          kind: openAiKind,
          defaultModel: 'gpt-5.6-sol',
          credential: 'provider:openai',
        ),
      );
      settings.setShareTasksWithCloud(true);
      settings.selectLlm('openai');
      return (
        c,
        () async {
          final body =
              jsonDecode(stub.requests.single.body) as Map<String, Object?>;
          final first = (body['input']! as List).first as Map<String, Object?>;
          expect(
            first['role'],
            'developer',
            reason: 'the Responses API reads instructions under developer',
          );
          return first['content']! as String;
        },
      );
    },
    chatGptKind: () async {
      final sidecar = File(p.join(tmp.path, 'Helpers', 'codex-app-server'))
        ..createSync(recursive: true)
        ..writeAsStringSync('stub');
      final server = FakeAppServer();
      final c = ProviderContainer.test(
        overrides: [
          ...base(),
          environmentProvider.overrideWithValue({'HOME': tmp.path}),
          identityProvider.overrideWithValue(SaiIdentity.stable),
          processRunnerProvider.overrideWithValue(server.runner),
          sidecarLocatorProvider.overrideWithValue(
            SidecarLocator(sidecar.path),
          ),
        ],
      );
      final settings = c.read(settingsProvider.notifier);
      settings.upsertProvider(
        ProviderConfig(
          id: 'chatgpt',
          kind: chatGptKind,
          defaultModel: 'gpt-5.6-sol',
        ),
      );
      settings.setShareTasksWithCloud(true);
      settings.selectLlm('chatgpt');
      return (
        c,
        () async {
          final start = server.threadStarts.singleWhere(
            (params) => params.containsKey('baseInstructions'),
          );
          // With sharing on the compact context rides as an item; only
          // the profile is the thread's base.
          expect(
            server.injections.single['items'],
            hasLength(1),
            reason: 'the task context is an item, the profile the base',
          );
          return start['baseInstructions']! as String;
        },
      );
    },
  };

  for (final MapEntry(key: kind, value: prepare) in recipes.entries) {
    test(
      '$kind is told the profile first, in the log and on the wire',
      () async {
        final (c, wire) = await prepare();
        await c.read(tasksProvider.future);
        await c
            .read(tasksProvider.notifier)
            .store
            .createTask(
              title: 'Call mom',
              when: const TaskWhen.date(CalendarDate(2026, 8, 25)),
            );
        final ok = await c.read(chatProvider.notifier).send('what is due?');
        final state = c.read(chatProvider);
        expect(ok, isTrue, reason: state.error ?? 'the send was refused');
        expect(state.turns.last.failed, isFalse, reason: state.turns.last.text);
        final sent = requests();
        expect(sent, hasLength(1));
        final messages = (sent.single['payload']! as Map)['messages']! as List;
        expect(messages.first, {'role': 'system', 'text': assistantProfile});
        expect(await wire(), assistantProfile);
      },
    );
  }

  test('every provider kind this build offers is covered', () {
    final c = ProviderContainer.test(
      overrides: [...base(), sidecarLocatorProvider.overrideWithValue(null)],
    );
    expect(
      recipes.keys.toSet(),
      c.read(llmFactoriesProvider).keys.toSet(),
      reason: 'a sixth provider kind must prove it carries the profile too',
    );
  });
}

class _FixedToday extends TodayNotifier {
  @override
  CalendarDate build() => const CalendarDate(2026, 8, 25);
}
