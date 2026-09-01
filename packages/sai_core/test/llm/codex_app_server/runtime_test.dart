import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

import 'package:sai_core/process_testing.dart';
import 'package:sai_core/src/process/posix.dart';

void main() {
  late Directory tmp;
  late FakeAppServer server;
  late AppServerRuntime runtime;
  late File sidecar;

  CodexLaunch launch({
    bool sandboxed = true,
    SidecarLocator? locator,
    FakeAppServer? on,
    String data = 'data',
  }) => CodexLaunch(
    sidecar: locator ?? SidecarLocator(sidecar.path),
    home: Directory(p.join(tmp.path, data, 'codex')),
    tempRoot: Directory(p.join(tmp.path, data, 'codex-tmp')),
    keychainsDir: Directory(p.join(tmp.path, 'Library', 'Keychains')),
    runner: (on ?? server).runner,
    clientVersion: '0.0.1-test',
    sandboxed: sandboxed,
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_codex_runtime');
    sidecar = File(p.join(tmp.path, 'Helpers', 'codex-app-server'))
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\nexit 1\n');
    server = FakeAppServer();
    runtime = AppServerRuntime(
      launch(),
      graceOnCancel: const Duration(milliseconds: 100),
    );
  });

  tearDown(() async {
    await runtime.close();
    tmp.deleteSync(recursive: true);
  });

  test(
    'starts under sandbox-exec with the minimal environment, once',
    () async {
      final account = await runtime.account();
      expect(account.isChatGpt, isTrue);
      expect(account.planType, 'pro');
      final spawn = server.runner.spawns.single;
      expect(spawn.executable, '/usr/bin/sandbox-exec');
      expect(spawn.arguments.first, '-p');
      expect(spawn.arguments.last, 'app-server');
      expect(spawn.arguments[spawn.arguments.length - 2], sidecar.path);
      final home = p.join(tmp.path, 'data', 'codex');
      expect(spawn.arguments, contains('CODEX_HOME=$home'));
      // The environment is exactly this — nothing inherited, no key.
      expect(spawn.environment, {
        'CODEX_HOME': home,
        'HOME': home,
        'TMPDIR': p.join(tmp.path, 'data', 'codex-tmp'),
        'LANG': 'en_US.UTF-8',
        'RUST_LOG': 'warn',
        'PATH': '/usr/bin:/bin',
      });
      expect(
        spawn.environment.keys.where((k) => k.startsWith('OPENAI_')),
        isEmpty,
      );
      expect(spawn.environment.keys.where((k) => k.startsWith('CODEX_')), [
        'CODEX_HOME',
      ]);
      expect(
        spawn.workingDirectory,
        p.join(tmp.path, 'data', 'codex-tmp', 'scratch'),
      );
      // The home was prepared before the spawn.
      expect(
        File(p.join(home, 'config.toml')).readAsStringSync(),
        codexConfigToml,
      );
      expect(File(p.join(home, 'lock')).existsSync(), isTrue);
      // initialize first, then initialized, then the call.
      final written = server.runner.processes.single.written;
      expect(written[0]['method'], 'initialize');
      expect((written[0]['params'] as Map)['clientInfo'], {
        'name': 'sai',
        'title': 'sai',
        'version': '0.0.1-test',
      });
      expect(written[1]['method'], 'initialized');
      expect(written[1], isNot(contains('id')));
      expect(written[2]['method'], 'account/read');
      // A second call reuses the child.
      await runtime.models();
      expect(server.runner.spawns, hasLength(1));
      expect(runtime.isRunning, isTrue);
    },
  );

  test('a parent key never reaches the child', () async {
    await runtime.account();
    final env = server.runner.spawns.single.environment;
    expect(env, isNot(contains('OPENAI_API_KEY')));
    expect(env, isNot(contains('CODEX_API_KEY')));
    expect(env, isNot(contains('HTTP_PROXY')));
    final personsHome = Platform.environment['HOME'];
    if (personsHome != null && personsHome.isNotEmpty) {
      expect(
        env.values.any(
          (v) => v.startsWith(personsHome) && !v.startsWith(tmp.path),
        ),
        isFalse,
        reason: 'the person\'s own home is not in the child\'s environment',
      );
    }
  });

  test('without the sandbox the sidecar is the executable itself', () async {
    await runtime.close();
    runtime = AppServerRuntime(launch(sandboxed: false));
    await runtime.account();
    final spawn = server.runner.spawns.single;
    expect(spawn.executable, sidecar.path);
    expect(spawn.arguments, ['app-server']);
  });

  test('no sidecar, no spawn; a start that fails releases the lock', () async {
    await runtime.close();
    runtime = AppServerRuntime(
      launch(locator: SidecarLocator(p.join(tmp.path, 'nowhere'))),
    );
    final missing = await runtime.account().then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );
    expect((missing as CodexException).text, CodexText.sidecarMissing);
    expect(missing.credential, isTrue);
    expect(server.runner.spawns, isEmpty);
    await runtime.close();
    server.runner.startError = const ProcessException('x', []);
    runtime = AppServerRuntime(launch());
    final failed = await runtime.account().then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );
    expect((failed as CodexException).text, CodexText.startFailed);
    // The lock is free again: another runtime in this process can take it.
    server.runner.startError = null;
    final again = AppServerRuntime(launch());
    expect((await again.account()).isChatGpt, isTrue);
    await again.close();
  });

  test('a runtime that opened another home is not used', () async {
    server.codexHome = '/Users/x/.codex';
    final error = await runtime.account().then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );
    expect((error as CodexException).text, CodexText.wrongHome);
    expect(
      server.runner.processes.single.signals,
      contains(ProcessSignal.sigterm),
    );
  });

  test('the temp root and the scratch root are sai\'s alone: a symlink is '
      'refused before any spawn, an open mode is closed', () async {
    final data = Directory(p.join(tmp.path, 'data'))..createSync();
    final elsewhere = Directory(p.join(tmp.path, 'elsewhere'))..createSync();
    final link = Link(p.join(data.path, 'codex-tmp'))
      ..createSync(elsewhere.path);
    final error = await runtime.account().then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );
    expect((error as CodexException).text, CodexText.homeUnsafe);
    expect(server.runner.spawns, isEmpty);
    // Roots that already exist too open are restricted on every start.
    link.deleteSync();
    final root = Directory(p.join(data.path, 'codex-tmp'))..createSync();
    final scratch = Directory(p.join(root.path, 'scratch'))..createSync();
    posixChmod(root.path, 0x1ed);
    posixChmod(scratch.path, 0x1ed);
    await runtime.account();
    expect(codexHomeMode(root), 0x1c0);
    expect(codexHomeMode(scratch), 0x1c0);
  });

  test('a runtime whose initialize names no home is not used', () async {
    server.reportHome = false;
    final error = await runtime.account().then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );
    expect((error as CodexException).text, CodexText.wrongHome);
    expect(
      server.runner.processes.single.signals,
      contains(ProcessSignal.sigterm),
    );
  });

  test('the child failing to initialize is a start failure', () async {
    server.runner.script = (p, line) {
      if (line['method'] == 'initialize') p.fail(line['id'], -32600, 'nope');
    };
    final error = await runtime.account().then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );
    expect((error as CodexException).text, CodexText.startFailed);
  });

  group('account and login', () {
    test('signed out and API-key logins are read as they are', () async {
      server.account = null;
      expect((await runtime.account()).type, CodexAccountType.none);
      server.account = {'type': 'apiKey'};
      expect((await runtime.account()).type, CodexAccountType.apiKey);
    });

    test('browser login returns the URL, device login the code; cancel '
        'cancels', () async {
      final browser = await runtime.startLogin(deviceCode: false);
      expect(browser.authUrl, startsWith('https://auth.openai.com/'));
      expect(browser.isDeviceCode, isFalse);
      expect(server.logins.last, {'type': 'chatgpt'});
      final device = await runtime.startLogin(deviceCode: true);
      expect(device.userCode, 'ABCD-1234');
      expect(device.verificationUrl, 'https://auth.openai.com/codex/device');
      expect(server.logins.last, {'type': 'chatgptDeviceCode'});
      final completed = <({String? loginId, bool success})>[];
      runtime.loginCompleted.listen(completed.add);
      await runtime.cancelLogin(device.loginId);
      await Future<void>.delayed(Duration.zero);
      expect(server.loginCancels, [
        {'loginId': device.loginId},
      ]);
      expect(completed.single, (loginId: device.loginId, success: false));
    });

    test('a login under way keeps the child busy until it completes, is '
        'cancelled, or the child goes', () async {
      final browser = await runtime.startLogin(deviceCode: false);
      expect(runtime.isBusy, isTrue);
      await runtime.releaseIdle();
      expect(runtime.isRunning, isTrue, reason: 'a login under way stays');
      final process = server.runner.processes.single;
      expect(process.signals, isEmpty);
      process.notify('account/login/completed', {
        'loginId': browser.loginId,
        'success': true,
      });
      await Future<void>.delayed(Duration.zero);
      expect(runtime.isBusy, isFalse);
      // Cancelling releases it too.
      final device = await runtime.startLogin(deviceCode: true);
      expect(runtime.isBusy, isTrue);
      await runtime.cancelLogin(device.loginId);
      await Future<void>.delayed(Duration.zero);
      expect(runtime.isBusy, isFalse);
      // A child that goes away mid-login leaves nothing counted.
      await runtime.startLogin(deviceCode: false);
      expect(runtime.isBusy, isTrue);
      process.exit(0);
      while (runtime.isRunning) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(runtime.isBusy, isFalse);
    });

    test('login completion and account updates are relayed', () async {
      await runtime.account();
      var updates = 0;
      final completed = <({String? loginId, bool success})>[];
      runtime.accountUpdates.listen((_) => updates++);
      runtime.loginCompleted.listen(completed.add);
      final p = server.runner.processes.single;
      p.notify('account/login/completed', {
        'loginId': 'login-9',
        'success': true,
      });
      p.notify('account/updated', {'authMode': 'chatgpt', 'planType': 'plus'});
      await Future<void>.delayed(Duration.zero);
      expect(completed.single, (loginId: 'login-9', success: true));
      expect(updates, 1);
    });

    test('logout asks the runtime and touches nothing of sai\'s', () async {
      await runtime.logout();
      expect(server.logouts, 1);
      expect((await runtime.account()).type, CodexAccountType.none);
      final home = Directory(p.join(tmp.path, 'data', 'codex'));
      expect(home.listSync().map((e) => p.basename(e.path)).toSet(), {
        'config.toml',
        'lock',
      });
    });
  });

  test('models are read whole, hidden ones left out, with efforts', () async {
    final models = await runtime.models();
    expect(models.map((m) => m.id), ['gpt-5.6-sol', 'gpt-5.6-luna']);
    expect(models.first.displayName, 'GPT-5.6 Sol');
    expect(models.first.isDefault, isTrue);
    expect(models.first.defaultEffort, const ReasoningEffort('medium'));
    expect(models.last.takes(const ReasoningEffort('xhigh')), isFalse);
    expect(models.last.takes(const ReasoningEffort('high')), isTrue);
  });

  test('rate limits are read, and updates relayed', () async {
    final limits = await runtime.rateLimits();
    expect(limits.primary!.usedPercent, 25);
    expect(limits.planType, 'pro');
    final updates = <CodexRateLimits>[];
    runtime.rateLimitUpdates.listen(updates.add);
    server.runner.processes.single.notify('account/rateLimits/updated', {
      'rateLimits': {
        'primary': {'usedPercent': 40},
      },
    });
    await Future<void>.delayed(Duration.zero);
    expect(updates.single.primary!.usedPercent, 40);
  });

  group('a turn', () {
    final messages = [
      const LlmMessage(LlmRole.system, 'be brief'),
      const LlmMessage(LlmRole.system, 'memory'),
      const LlmMessage(LlmRole.user, 'q1'),
      const LlmMessage(LlmRole.assistant, 'a1'),
      const LlmMessage(LlmRole.user, 'q2'),
    ];

    Future<CodexTurnOutcome> run({
      ReasoningEffort? effort,
      Map<String, Object?>? schema,
      Completer<void>? cancel,
      List<String>? text,
      List<String>? thoughts,
      AppServerRuntime? on,
    }) => (on ?? runtime).turn(
      model: 'gpt-5.6-sol',
      effort: effort,
      messages: messages,
      outputSchema: schema,
      onText: (t) => text?.add(t),
      onReasoning: (t) => thoughts?.add(t),
      cancelled: (cancel ?? Completer<void>()).future,
    );

    test('is a fresh ephemeral read-only thread in a scratch dir, the '
        'history injected in order, the last message the turn', () async {
      server.reasoning = 'hmm';
      final text = <String>[];
      final thoughts = <String>[];
      final outcome = await run(
        effort: const ReasoningEffort('xhigh'),
        schema: {'type': 'object'},
        text: text,
        thoughts: thoughts,
      );
      expect(outcome.status, CodexTurnStatus.completed);
      expect(outcome.model, 'gpt-5.6-sol');
      expect(outcome.usage!.totalTokens, 14);
      expect(text, ['ready', '.']);
      expect(thoughts, ['hmm']);
      final thread = server.threadStarts.single;
      expect(thread['model'], 'gpt-5.6-sol');
      expect(thread['ephemeral'], isTrue);
      expect(thread['sandbox'], 'read-only');
      expect(thread['approvalPolicy'], 'never');
      expect(thread['baseInstructions'], 'be brief');
      expect(thread['config'], codexThreadConfig);
      final cwd = thread['cwd'] as String;
      expect(
        p.isWithin(p.join(tmp.path, 'data', 'codex-tmp', 'scratch'), cwd),
        isTrue,
      );
      expect(
        Directory(cwd).existsSync(),
        isFalse,
        reason: 'deleted after the turn',
      );
      expect(server.injections.single['items'], [
        {
          'type': 'message',
          'role': 'developer',
          'content': [
            {'type': 'input_text', 'text': 'memory'},
          ],
        },
        {
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'q1'},
          ],
        },
        {
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 'a1'},
          ],
        },
      ]);
      final turn = server.turnStarts.single;
      expect(turn['input'], [
        {'type': 'text', 'text': 'q2'},
      ]);
      expect(turn['effort'], 'xhigh');
      expect(turn['outputSchema'], {'type': 'object'});
      expect(turn, isNot(contains('model')), reason: 'the thread carries it');
      // One system message and the last user message: nothing injected.
      await runtime.turn(
        model: 'gpt-5.6-sol',
        effort: null,
        messages: const [
          LlmMessage(LlmRole.system, 's'),
          LlmMessage(LlmRole.user, 'u'),
        ],
        onText: (_) {},
        onReasoning: (_) {},
        cancelled: Completer<void>().future,
      );
      expect(server.injections, hasLength(1));
      expect(
        server.turnStarts.last,
        isNot(contains('effort')),
        reason: 'Model default',
      );
    });

    test('deltas of another thread or turn are not this turn\'s', () async {
      server.turnScript = (p, threadId, turnId) {
        p.notify('item/agentMessage/delta', {
          'threadId': 'other',
          'turnId': turnId,
          'itemId': 'x',
          'delta': 'NOT',
        });
        p.notify('item/agentMessage/delta', {
          'threadId': threadId,
          'turnId': 'stale',
          'itemId': 'x',
          'delta': 'NOT',
        });
        p.notify('thread/tokenUsage/updated', {
          'threadId': 'other',
          'turnId': turnId,
          'tokenUsage': {
            'last': {
              'inputTokens': 999,
              'outputTokens': 9,
              'totalTokens': 1008,
              'cachedInputTokens': 0,
              'reasoningOutputTokens': 0,
            },
            'total': <String, Object?>{},
          },
        });
        p.notify('turn/completed', {
          'threadId': 'other',
          'turn': {'id': turnId, 'status': 'failed', 'items': <Object>[]},
        });
        server.streamAnswer(p, threadId, turnId);
      };
      final text = <String>[];
      final outcome = await run(text: text);
      expect(text, ['ready', '.']);
      expect(outcome.status, CodexTurnStatus.completed);
      expect(outcome.usage!.totalTokens, 14);
    });

    test('a rerouted model is the lineage', () async {
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
      expect((await run()).model, 'gpt-5.6-safe');
    });

    test('a failed turn carries its error class, never its text', () async {
      for (final (info, klass) in [
        ('usageLimitExceeded', CodexErrorClass.planLimit),
        ('unauthorized', CodexErrorClass.unauthorized),
        ('serverOverloaded', CodexErrorClass.overloaded),
        ('internalServerError', CodexErrorClass.other),
      ]) {
        server.turnScript = (p, threadId, turnId) {
          p.notify('error', {
            'threadId': threadId,
            'turnId': turnId,
            'willRetry': true,
            'error': {
              'message': 'transient',
              'codexErrorInfo': 'serverOverloaded',
            },
          });
          p.notify('turn/completed', {
            'threadId': threadId,
            'turn': {
              'id': turnId,
              'status': 'failed',
              'items': <Object>[],
              'error': {
                'message': 'sk-canary secret text',
                'codexErrorInfo': info,
              },
            },
          });
        };
        final outcome = await run();
        expect(outcome.status, CodexTurnStatus.failed, reason: info);
        expect(outcome.errorClass, klass, reason: info);
        expect('$outcome', isNot(contains('sk-canary')));
      }
    });

    test(
      'any active item or server request stops the turn, fail closed',
      () async {
        for (final type in [
          'commandExecution',
          'fileChange',
          'mcpToolCall',
          'webSearch',
          'collabToolCall',
          'plan',
          'brandNewThing',
        ]) {
          server.interrupts.clear();
          server.turnScript = (p, threadId, turnId) {
            p.notify('item/agentMessage/delta', {
              'threadId': threadId,
              'turnId': turnId,
              'itemId': 'm',
              'delta': 'before ',
            });
            p.notify('item/started', {
              'threadId': threadId,
              'turnId': turnId,
              'startedAtMs': 1,
              'item': {'type': type, 'id': 'c1', 'command': 'rm -rf /'},
            });
            // The fake answers the interrupt with turn/completed interrupted.
          };
          final text = <String>[];
          final outcome = await run(text: text);
          expect(outcome.unsafe, isTrue, reason: type);
          expect(outcome.status, CodexTurnStatus.interrupted, reason: type);
          expect(server.interrupts, hasLength(1), reason: type);
          expect(text, ['before ']);
        }
        // A server request: declined, then the turn interrupted.
        server.interrupts.clear();
        server.turnScript = (p, threadId, turnId) {
          p.ask(500, 'item/commandExecution/requestApproval', {
            'threadId': threadId,
            'turnId': turnId,
            'itemId': 'c',
            'command': 'ls',
          });
        };
        final outcome = await run();
        expect(outcome.unsafe, isTrue);
        expect(server.interrupts, hasLength(1));
        final declined = server.runner.processes.single.written
            .where((w) => w['id'] == 500)
            .single;
        expect(declined['error'], {'code': -32601, 'message': 'declined'});
      },
    );

    test('cancel interrupts the turn and keeps what came', () async {
      final gate = Completer<void>();
      server.turnScript = (p, threadId, turnId) {
        p.notify('item/agentMessage/delta', {
          'threadId': threadId,
          'turnId': turnId,
          'itemId': 'm',
          'delta': 'part',
        });
        gate.complete();
      };
      final cancel = Completer<void>();
      final text = <String>[];
      final pending = run(cancel: cancel, text: text);
      await gate.future;
      cancel.complete();
      final outcome = await pending;
      expect(outcome.status, CodexTurnStatus.interrupted);
      expect(text, ['part']);
      expect(server.interrupts, hasLength(1));
      expect(runtime.isRunning, isTrue, reason: 'it answered; it stays');
    });

    test(
      'a runtime that ignores the interrupt is terminated after the grace',
      () async {
        final stubborn = FakeAppServer();
        final original = stubborn.runner.script!;
        final gate = Completer<void>();
        stubborn.turnScript = (p, threadId, turnId) => gate.complete();
        stubborn.runner.script = (p, line) {
          if (line['method'] == 'turn/interrupt') {
            p.reply(line['id'], <String, Object?>{});
            return; // never a turn/completed
          }
          original(p, line);
        };
        final other = AppServerRuntime(
          launch(on: stubborn, data: 'data2'),
          graceOnCancel: const Duration(milliseconds: 50),
        );
        final cancel = Completer<void>();
        final pending = run(on: other, cancel: cancel);
        await gate.future;
        cancel.complete();
        final outcome = await pending;
        expect(outcome.protocolFailure, CodexText.closed);
        expect(
          stubborn.runner.processes.single.signals,
          contains(ProcessSignal.sigterm),
        );
        expect(other.isRunning, isFalse);
        await other.close();
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test('the child exiting mid-turn fails the turn; the next call '
        'starts afresh', () async {
      server.turnScript = (p, threadId, turnId) {
        p.notify('item/agentMessage/delta', {
          'threadId': threadId,
          'turnId': turnId,
          'itemId': 'm',
          'delta': 'half',
        });
        p.exit(137);
      };
      final text = <String>[];
      final outcome = await run(text: text);
      expect(outcome.protocolFailure, CodexText.childExited);
      expect(text, ['half']);
      expect(runtime.isRunning, isFalse);
      server.turnScript = null;
      expect((await run()).status, CodexTurnStatus.completed);
      expect(server.runner.spawns, hasLength(2));
    });

    test('the last message must be the user\'s', () async {
      final error = await runtime
          .turn(
            model: 'm',
            effort: null,
            messages: const [
              LlmMessage(LlmRole.user, 'q'),
              LlmMessage(LlmRole.assistant, 'a'),
            ],
            onText: (_) {},
            onReasoning: (_) {},
            cancelled: Completer<void>().future,
          )
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect((error as CodexException).text, CodexText.rejected);
      expect(server.threadStarts, isEmpty);
    });
  });

  group('lifecycle', () {
    test('releaseIdle ends an idle child and frees the lock; a busy one '
        'is left alone', () async {
      await runtime.account();
      final process = server.runner.processes.single;
      expect(runtime.isRunning, isTrue);
      final gate = Completer<void>();
      final finish = Completer<void>();
      server.turnScript = (p, threadId, turnId) {
        gate.complete();
        finish.future.then((_) => server.streamAnswer(p, threadId, turnId));
      };
      final pending = runtime.turn(
        model: 'gpt-5.6-sol',
        effort: null,
        messages: const [LlmMessage(LlmRole.user, 'q')],
        onText: (_) {},
        onReasoning: (_) {},
        cancelled: Completer<void>().future,
      );
      await gate.future;
      expect(runtime.isBusy, isTrue);
      await runtime.releaseIdle();
      expect(runtime.isRunning, isTrue, reason: 'a turn under way stays');
      expect(process.signals, isEmpty);
      finish.complete();
      await pending;
      expect(runtime.isBusy, isFalse);
      // A child that exits on SIGTERM: no SIGKILL.
      process.onLine = null;
      final releasing = runtime.releaseIdle();
      await Future<void>.delayed(Duration.zero);
      expect(process.signals, [ProcessSignal.sigterm]);
      process.exit(0);
      await releasing;
      expect(runtime.isRunning, isFalse);
      expect(process.signals, [ProcessSignal.sigterm]);
      // Another runtime on the same home can start: the lock is free.
      final other = AppServerRuntime(launch());
      expect((await other.account()).isChatGpt, isTrue);
      await other.close();
    });

    test('a connection that ends on a bad line ends the child too; no '
        'orphan keeps the login', () async {
      await runtime.account();
      final process = server.runner.processes.single;
      process.emitRaw('thread panicked: not a line the protocol knows\n');
      while (process.signals.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(process.signals, [ProcessSignal.sigterm]);
      expect(runtime.isRunning, isFalse);
      process.exit(0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // The home is free again: another runtime starts on it.
      final other = AppServerRuntime(launch());
      expect((await other.account()).isChatGpt, isTrue);
      await other.close();
    });

    test(
      'close while starting waits for the start and ends its child',
      () async {
        final hold = Completer<void>();
        server.holdInitialize = hold.future;
        final starting = runtime.account();
        while (server.runner.processes.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        final process = server.runner.processes.single;
        final closing = runtime.close();
        hold.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        process.exit(0);
        final error = await starting.then<Object?>(
          (_) => null,
          onError: (Object e) => e,
        );
        expect((error as CodexException).text, CodexText.closed);
        await closing;
        expect(process.signals, contains(ProcessSignal.sigterm));
        expect(runtime.isRunning, isFalse);
        // The lock is free: another runtime on the same home starts.
        final other = AppServerRuntime(launch());
        expect((await other.account()).isChatGpt, isTrue);
        await other.close();
      },
    );

    test('close terminates, then kills a child that lingers', () async {
      final quick = AppServerRuntime(launch(data: 'data3'));
      await quick.account();
      final process = server.runner.processes.single;
      final closing = quick.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(process.signals, [ProcessSignal.sigterm]);
      await closing;
      expect(process.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
      final after = await quick.account().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      expect((after as CodexException).text, CodexText.closed);
    }, timeout: const Timeout(Duration(seconds: 15)));
  });
}
