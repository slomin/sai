import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

import '../provider_contract.dart';
import 'fake_app_server.dart';

void main() {
  late Directory tmp;
  late FakeAppServer server;
  late AppServerRuntime runtime;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_codex_provider');
    final sidecar = File(p.join(tmp.path, 'Helpers', 'codex-app-server'))
      ..createSync(recursive: true)
      ..writeAsStringSync('stub');
    server = FakeAppServer();
    runtime = AppServerRuntime(
      CodexLaunch(
        sidecar: SidecarLocator(sidecar.path),
        home: Directory(p.join(tmp.path, 'data', 'codex')),
        tempRoot: Directory(p.join(tmp.path, 'data', 'codex-tmp')),
        keychainsDir: Directory(p.join(tmp.path, 'Library', 'Keychains')),
        runner: server.runner,
      ),
      graceOnCancel: const Duration(milliseconds: 100),
    );
  });

  tearDown(() async {
    await runtime.close();
    tmp.deleteSync(recursive: true);
  });

  ChatGptSubscriptionProvider make({
    String? model = 'gpt-5.6-sol',
    ReasoningEffort? effort,
    bool withRuntime = true,
  }) => ChatGptSubscriptionProvider(
    id: 'chatgpt',
    installedRuntime: withRuntime ? runtime : null,
    defaultModel: model,
    reasoningEffort: effort,
  );

  LlmRequest ask(String text, {ReasoningEffort? effort, String? model}) =>
      LlmRequest(
        messages: [LlmMessage(LlmRole.user, text)],
        reasoningEffort: effort,
        model: model,
      );

  group('against the scripted App Server', () {
    setUp(() => server.answer = ['one ', 'two ', 'three']);
    llmProviderContract(
      'ChatGptSubscriptionProvider',
      () => make(),
      request: () => ask('go'),
    );
  });

  test('gates first: account, then the pair; then one turn', () async {
    server.reasoning = 'hmm';
    final provider = make(effort: const ReasoningEffort('high'));
    final effort = requestedEffortFor(provider, reasoningOn: false);
    expect(effort, const ReasoningEffort('high'));
    final call = provider.start(ask('hi', effort: effort));
    final deltas = await call.deltas.toList();
    final result = await call.done;
    expect(result.finish, LlmFinish.stop);
    expect(result.text, 'ready.');
    expect(result.reasoning, 'hmm');
    expect(deltas.map((d) => (d.text, d.reasoning)), [
      ('hmm', true),
      ('ready', false),
      ('.', false),
    ]);
    expect(result.model.provider, 'chatgpt');
    expect(result.model.id, 'gpt-5.6-sol');
    expect(result.model.version, isNull, reason: 'answered as asked');
    expect(result.usage!.promptTokens, 12);
    expect(result.usage!.completionTokens, 2);
    expect(result.usage!.cost, isNull);
    // account/read, model/list, then the thread — no prompt before the
    // gates.
    final methods = server.runner.processes.single.written
        .map((w) => w['method'])
        .toList();
    expect(methods, [
      'initialize',
      'initialized',
      'account/read',
      'model/list',
      'thread/start',
      'turn/start',
    ]);
    expect(server.turnStarts.single['effort'], 'high');
    expect(provider.displayName, 'chatgpt @ ChatGPT');
    expect(provider.privacy, LlmPrivacy.cloud);
    expect(provider.kind, chatGptKind);
    expect(provider.hasModel, isTrue);
    expect(provider.lastCatalogue!.map((m) => m.id), [
      'gpt-5.6-sol',
      'gpt-5.6-luna',
    ]);
  });

  test(
    'a rerouted answer names the model that answered as the version',
    () async {
      server.turnScript = (p, threadId, turnId) {
        p.notify('model/rerouted', {
          'threadId': threadId,
          'turnId': turnId,
          'fromModel': 'gpt-5.6-sol',
          'toModel': 'gpt-5.6-safe',
          'reason': 'x',
        });
        server.streamAnswer(p, threadId, turnId);
      };
      final result = await make().start(ask('x')).done;
      expect(result.model.id, 'gpt-5.6-sol');
      expect(result.model.version, 'gpt-5.6-safe');
    },
  );

  group('refusals before any prompt', () {
    Future<LlmResult> refused(
      ChatGptSubscriptionProvider provider,
      LlmRequest request,
    ) async {
      final result = await provider.start(request).done;
      expect(result.finish, LlmFinish.failed);
      expect(server.threadStarts, isEmpty, reason: 'no prompt went');
      expect(server.turnStarts, isEmpty);
      return result;
    }

    test('signed out, or signed in with an API key', () async {
      server.account = null;
      var result = await refused(make(), ask('x'));
      expect(result.failure!.kind, LlmFailureKind.credential);
      expect(result.failure!.message, CodexText.signedOut);
      server.account = {'type': 'apiKey'};
      result = await refused(make(), ask('x'));
      expect(result.failure!.kind, LlmFailureKind.credential);
      expect(result.failure!.message, CodexText.wrongAuth);
    });

    test('no model chosen yet', () async {
      final provider = make(model: null);
      expect(provider.hasModel, isFalse);
      expect(provider.defaultModel, CodexText.chooseModel);
      final result = await refused(provider, ask('x'));
      expect(result.failure!.message, CodexText.chooseModel);
      expect(server.accountReads, 0, reason: 'refused before a spawn');
    });

    test(
      'a model the list no longer carries is refused, never swapped',
      () async {
        final result = await refused(make(model: 'gpt-5.5-gone'), ask('x'));
        expect(result.failure!.kind, LlmFailureKind.rejected);
        expect(result.failure!.message, CodexText.modelUnavailable);
      },
    );

    test(
      'an effort the model does not take is refused, never changed',
      () async {
        final provider = make(
          model: 'gpt-5.6-luna',
          effort: const ReasoningEffort('xhigh'),
        );
        final result = await refused(
          provider,
          ask('x', effort: requestedEffortFor(provider, reasoningOn: true)),
        );
        expect(result.failure!.message, CodexText.effortUnavailable);
        // The same model with an effort it takes goes through.
        final ok = await provider
            .start(ask('x', effort: const ReasoningEffort('high')))
            .done;
        expect(ok.finish, LlmFinish.stop);
        expect(server.turnStarts.single['effort'], 'high');
      },
    );

    test('a temperature is refused: the runtime has no such field', () async {
      final result = await refused(
        make(),
        LlmRequest(
          messages: const [LlmMessage(LlmRole.user, 'x')],
          temperature: 0,
        ),
      );
      expect(result.failure!.message, CodexText.temperatureUnsupported);
      expect(server.accountReads, 0);
    });

    test('the provider test request passes with no temperature', () async {
      final result = await make()
          .start(providerTestRequest(temperature: null))
          .done;
      expect(result.finish, LlmFinish.stop);
    });
  });

  group('the dev copy and a build without the sidecar', () {
    test('refuse in fixed words before any spawn', () async {
      final provider = make(withRuntime: false);
      expect(provider.hasRuntime, isFalse);
      final result = await provider.start(ask('x')).done;
      expect(result.failure!.kind, LlmFailureKind.credential);
      expect(result.failure!.message, CodexText.devRefused);
      final info = await provider.probe();
      expect(info.health, EndpointHealth.unavailable);
      expect(info.failure!.message, CodexText.devRefused);
      provider.releaseIdle();
      await provider.close();
      expect(server.runner.spawns, isEmpty);
    });
  });

  test('turn outcomes map to finishes and fixed words', () async {
    Future<LlmResult> outcome(String status, {String? info}) async {
      server.turnScript = (p, threadId, turnId) {
        p.notify('item/agentMessage/delta', {
          'threadId': threadId,
          'turnId': turnId,
          'itemId': 'm',
          'delta': 'part',
        });
        p.notify('turn/completed', {
          'threadId': threadId,
          'turn': {
            'id': turnId,
            'status': status,
            'items': <Object>[],
            if (info != null)
              'error': {'message': 'quoted sk-canary', 'codexErrorInfo': info},
          },
        });
      };
      final result = await make().start(ask('x')).done;
      expect(result.text, 'part');
      expect('$result', isNot(contains('sk-canary')));
      return result;
    }

    var r = await outcome('failed', info: 'usageLimitExceeded');
    expect(
      (r.failure!.kind, r.failure!.message),
      (LlmFailureKind.rejected, CodexText.planLimit),
    );
    r = await outcome('failed', info: 'unauthorized');
    expect(
      (r.failure!.kind, r.failure!.message),
      (LlmFailureKind.credential, CodexText.unauthorized),
    );
    r = await outcome('failed', info: 'serverOverloaded');
    expect(r.failure!.message, CodexText.overloaded);
    r = await outcome('failed', info: 'internalServerError');
    expect(r.failure!.message, CodexText.errorPayload);
    r = await outcome('interrupted');
    expect(r.failure!.message, CodexText.rejected);
  });

  test(
    'an unsafe event is a protocol failure with what came before it',
    () async {
      server.turnScript = (p, threadId, turnId) {
        p.notify('item/agentMessage/delta', {
          'threadId': threadId,
          'turnId': turnId,
          'itemId': 'm',
          'delta': 'let me ',
        });
        p.notify('item/started', {
          'threadId': threadId,
          'turnId': turnId,
          'startedAtMs': 1,
          'item': {
            'type': 'commandExecution',
            'id': 'c',
            'command': 'cat ~/.ssh/id_rsa',
          },
        });
      };
      final result = await make().start(ask('x')).done;
      expect(result.finish, LlmFinish.failed);
      expect(result.failure!.kind, LlmFailureKind.protocol);
      expect(result.failure!.message, CodexText.unsafe);
      expect(result.text, 'let me ');
      expect(server.interrupts, hasLength(1));
      expect('$result', isNot(contains('id_rsa')));
    },
  );

  test('the child exiting is unreachable; another sai holding the home is '
      'credential', () async {
    server.turnScript = (p, threadId, turnId) => p.exit(1);
    final result = await make().start(ask('x')).done;
    expect(result.failure!.kind, LlmFailureKind.unreachable);
    expect(result.failure!.message, CodexText.childExited);
  });

  test('probe reads the account and the model ids', () async {
    final info = await make().probe();
    expect(info.health, EndpointHealth.ok);
    expect(info.models, ['gpt-5.6-sol', 'gpt-5.6-luna']);
    expect(info.serverKind, chatGptKind);
    expect(info.contextWindow, isNull);
    server.account = null;
    final out = await make().probe();
    expect(out.health, EndpointHealth.unavailable);
    expect(out.failure!.kind, LlmFailureKind.credential);
    expect(out.failure!.message, CodexText.signedOut);
  });

  test('every failure word is fixed text', () {
    expect(CodexText.all, hasLength(greaterThan(20)));
    for (final word in CodexText.all) {
      expect(word, isNot(contains('http')));
      expect(word, isNot(contains('@')));
    }
  });
}
