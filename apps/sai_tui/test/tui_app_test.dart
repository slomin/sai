import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:sai_tui/chat_pane.dart';
import 'package:sai_tui/tui_app.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'pump.dart';

/// `testNocterm` is a plain async function, not a `test` registration, and
/// nocterm allows one binding at a time — so each call is wrapped in a
/// `test` and awaited.
void main() {
  const size = Size(72, 14);

  Future<ProviderContainer> pumpTui(
    NoctermTester tester, {
    void Function()? onQuit,
    List<Override> overrides = const [],
    bool settled = true,
  }) async {
    final container = testContainer(overrides: overrides);
    if (settled) await container.read(tasksProvider.future);
    await tester.pumpComponent(
      RiverpodScope(
        container: container,
        child: TuiApp(onQuit: onQuit ?? () {}),
      ),
    );
    return container;
  }

  test('an empty archive shows the greeting and the key hints', () async {
    await testNocterm('empty', (tester) async {
      await pumpTui(tester);
      expect(
        tester.terminalState,
        containsText('sai 2.0.0-dev — nothing here yet'),
      );
      expect(tester.terminalState, containsText('Capture to Inbox'));
      expect(tester.terminalState, containsText('^C quit'));
      expect(tester.terminalState, containsText('^U undo'));
    }, size: size);
  });

  test('the footer names the missing provider', () async {
    await testNocterm('no provider', (tester) async {
      await pumpTui(tester);
      expect(tester.terminalState, containsText(noProviderStatus));
    }, size: size);
  });

  test('the footer follows the selected provider', () async {
    await testNocterm('fake provider', (tester) async {
      final container = await pumpTui(tester);
      container.read(settingsProvider.notifier).selectLlm('fake');
      await pumpUntilText(tester, 'fake (fake-1) — local');
      expect(tester.terminalState, isNot(containsText(noProviderStatus)));
    }, size: size);
  });

  test('the footer says when the cloud provider gets no tasks', () async {
    await testNocterm('privacy footer', (tester) async {
      final container = await pumpTui(tester);
      final settings = container.read(settingsProvider.notifier);
      settings.upsertProvider(
        ProviderConfig(id: 'cloudy', kind: 'fake', privacy: LlmPrivacy.cloud),
      );
      settings.selectLlm('cloudy');
      await pumpUntilText(tester, 'cloudy (fake-1) — cloud · tasks withheld');
      settings.setShareTasksWithCloud(true);
      await pumpUntilText(tester, 'cloudy (fake-1) — cloud');
      await tester.pump(const Duration(milliseconds: 20));
      expect(tester.terminalState, isNot(containsText('tasks withheld')));
    }, size: size);
  });

  test('a long status line takes one row, not the list\'s', () async {
    await testNocterm('long status', (tester) async {
      final container = await pumpTui(tester);
      container.read(settingsProvider.notifier).selectLlm('x' * 60);
      await pumpUntilText(tester, 'provider ...');
      // Everything else is still on screen: the cut line took one row.
      expect(tester.terminalState, containsText('nothing here yet'));
      expect(tester.terminalState, containsText('^C quit'));
      expect(tester.terminalState, containsText('Capture to Inbox'));
    }, size: const Size(44, 10));
  });

  test('the shell reads through the shared provider layer', () async {
    await testNocterm('override', (tester) async {
      await pumpTui(
        tester,
        overrides: [
          appInfoProvider.overrideWithValue(
            const AppInfo(name: 'override', version: '0'),
          ),
        ],
      );
      expect(
        tester.terminalState,
        containsText('override 0 — nothing here yet'),
      );
    }, size: size);
  });

  test('a captured line lands in the Inbox and clears the field', () async {
    await testNocterm('capture', (tester) async {
      final container = await pumpTui(tester);
      await tester.enterText('Buy oat milk');
      await tester.sendEnter();
      await pumpUntilText(tester, 'Inbox (1)');
      expect(tester.terminalState, containsText('Buy oat milk'));
      // The cleared field shows its placeholder again.
      expect(tester.terminalState, containsText('Capture to Inbox'));
      expect(
        container.read(tasksProvider).value!.tasks.values.single.title,
        'Buy oat milk',
      );
    }, size: size);
  });

  test('a capture typed before the store settles still lands', () async {
    await testNocterm('early capture', (tester) async {
      // No pre-await: the field renders while the archive is opening.
      final container = await pumpTui(tester, settled: false);
      await tester.enterText('Buy oat milk');
      await tester.sendEnter();
      await pumpUntilText(tester, 'Inbox (1)');
      expect(
        container.read(tasksProvider).value!.tasks.values.single.title,
        'Buy oat milk',
      );
    }, size: size);
  });

  test('an @today capture surfaces under Today', () async {
    await testNocterm('today', (tester) async {
      await pumpTui(tester);
      await tester.enterText('Call mom @today');
      await tester.sendEnter();
      await pumpUntilText(tester, 'Today (1)');
      expect(tester.terminalState, containsText('Inbox (0)'));
      expect(tester.terminalState, containsText('Call mom @today'));
    }, size: size);
  });

  test('the visible lists react when the local day rolls over', () async {
    await testNocterm('midnight', (tester) async {
      final container = testContainer(
        overrides: [todayProvider.overrideWith(_TestToday.new)],
      );
      await container.read(tasksProvider.future);
      await container
          .read(tasksProvider.notifier)
          .store
          .createTask(
            title: 'Tomorrow task',
            when: const TaskWhen.date(CalendarDate(2026, 8, 25)),
          );
      await tester.pumpComponent(
        RiverpodScope(
          container: container,
          child: TuiApp(onQuit: () {}),
        ),
      );
      expect(tester.terminalState, containsText('Upcoming (1)'));
      expect(tester.terminalState, containsText('Today (0)'));

      (container.read(todayProvider.notifier) as _TestToday).advance();
      await pumpUntilText(tester, 'Today (1)');
      expect(tester.terminalState, containsText('Tomorrow task @today'));
    }, size: size);
  });

  test('a deadline token renders, in Inbox and in Upcoming', () async {
    await testNocterm('deadline', (tester) async {
      await pumpTui(tester);
      await tester.enterText('Pay rent !2026-09-01');
      await tester.sendEnter();
      await pumpUntilText(tester, 'Pay rent !2026-09-01');
      // The view union: a due-later Inbox task also surfaces in Upcoming.
      expect(tester.terminalState, containsText('Inbox (1)'));
      expect(tester.terminalState, containsText('Upcoming (1)'));
    }, size: size);
  });

  test('@tomorrow and @someday captures stay visible', () async {
    await testNocterm('later lists', (tester) async {
      await pumpTui(tester);
      await tester.enterText('Ring dentist @tomorrow');
      await tester.sendEnter();
      await pumpUntilText(tester, 'Upcoming (1)');
      expect(tester.terminalState, containsText('Ring dentist @tomorrow'));
      await tester.enterText('Learn the violin @someday');
      await tester.sendEnter();
      await pumpUntilText(tester, 'Someday (1)');
      expect(tester.terminalState, containsText('Learn the violin @someday'));
    }, size: size);
  });

  test('a failed capture keeps the line and says so', () async {
    await testNocterm('capture failure', (tester) async {
      final container = await pumpTui(tester);
      container.read(tasksProvider.notifier).store.dispose();
      await tester.enterText('Buy oat milk');
      await tester.sendEnter();
      await pumpUntilText(tester, 'capture failed:');
      // The line is given back rather than lost.
      expect(tester.terminalState, containsText('Buy oat milk'));
    }, size: size);
  });

  test('a blank line captures nothing', () async {
    await testNocterm('blank', (tester) async {
      final container = await pumpTui(tester);
      await tester.enterText('   ');
      await tester.sendEnter();
      await pumpFor(tester, const Duration(milliseconds: 200));
      expect(archiveLines(container), hasLength(0));
      expect(
        tester.terminalState,
        containsText('sai 2.0.0-dev — nothing here yet'),
      );
    }, size: size);
  });

  test('Ctrl+U undoes the last capture into the Trash', () async {
    await testNocterm('undo', (tester) async {
      final container = await pumpTui(tester);
      await tester.enterText('Buy oat milk');
      await tester.sendEnter();
      await pumpUntilText(tester, 'Inbox (1)');
      await tester.sendKeyEvent(
        const KeyboardEvent(
          logicalKey: LogicalKey.keyU,
          modifiers: ModifierKeys(ctrl: true),
        ),
      );
      await pumpUntilText(tester, 'nothing here yet');
      expect(
        container.read(tasksProvider).value!.trash().single.title,
        'Buy oat milk',
      );
    }, size: size);
  });

  test('Ctrl+U with nothing to undo says so', () async {
    await testNocterm('undo empty', (tester) async {
      await pumpTui(tester);
      await tester.sendKeyEvent(
        const KeyboardEvent(
          logicalKey: LogicalKey.keyU,
          modifiers: ModifierKeys(ctrl: true),
        ),
      );
      await pumpUntilText(tester, 'nothing to undo');
    }, size: size);
  });

  test('q types into the field; Ctrl+C quits', () async {
    await testNocterm('quit keys', (tester) async {
      var quits = 0;
      await pumpTui(tester, onQuit: () => quits++);
      await tester.enterText('q');
      await tester.pump();
      expect(quits, 0);
      expect(tester.terminalState, containsText('q'));

      await tester.sendKeyEvent(
        const KeyboardEvent(
          logicalKey: LogicalKey.keyC,
          modifiers: ModifierKeys(ctrl: true),
        ),
      );
      await tester.pump();
      expect(quits, 1);
    }, size: size);
  });

  test('a capture is an archive event with actor and source', () async {
    await testNocterm('archive line', (tester) async {
      final container = await pumpTui(tester);
      await tester.enterText('Buy oat milk');
      await tester.sendEnter();
      await pumpUntilText(tester, 'Inbox (1)');
      final lines = archiveLines(container);
      expect(lines, hasLength(1));
      final json = jsonDecode(lines.single) as Map<String, Object?>;
      expect(json['type'], 'task.create');
      expect(json['actor'], 'user');
      expect(json['source'], 'sai/tui');
      expect(() => parseTs(json['ts']! as String), returnsNormally);
    }, size: size);
  });

  test('an unsettled store shows the opening note', () async {
    await testNocterm('loading', (tester) async {
      await pumpTui(
        tester,
        settled: false,
        overrides: [tasksProvider.overrideWith(_StuckTasks.new)],
      );
      expect(tester.terminalState, containsText('opening the archive…'));
    }, size: size);
  });

  test('a failed open shows the error', () async {
    await testNocterm('error', (tester) async {
      await pumpTui(
        tester,
        settled: false,
        overrides: [tasksProvider.overrideWith(_FailingTasks.new)],
      );
      await pumpUntilText(tester, 'archive error:');
    }, size: size);
  });

  group('the list (#41)', () {
    const ctrlD = KeyboardEvent(
      logicalKey: LogicalKey.keyD,
      modifiers: ModifierKeys(ctrl: true),
    );
    const ctrlU = KeyboardEvent(
      logicalKey: LogicalKey.keyU,
      modifiers: ModifierKeys(ctrl: true),
    );

    /// Two Today tasks, `One` above `Two`; the cursor starts on `One`.
    Future<ProviderContainer> pumpTwo(NoctermTester tester) async {
      final container = testContainer();
      await container.read(tasksProvider.future);
      final store = container.read(tasksProvider.notifier).store;
      final today = container.read(todayProvider);
      for (final title in ['One', 'Two']) {
        await store.createTask(title: title, when: TaskWhen.date(today));
      }
      await tester.pumpComponent(
        RiverpodScope(
          container: container,
          child: TuiApp(onQuit: () {}),
        ),
      );
      await pumpUntilText(tester, '› One @today');
      return container;
    }

    test('the footer names the list keys', () async {
      await testNocterm('list keys', (tester) async {
        await pumpTui(tester);
        expect(tester.terminalState, containsText('^D done'));
        expect(tester.terminalState, containsText('↑↓ select'));
      }, size: size);
    });

    test('↓ and ↑ move the cursor and stop at the ends', () async {
      await testNocterm('cursor', (tester) async {
        await pumpTwo(tester);
        await tester.sendKey(LogicalKey.arrowUp);
        await tester.pump();
        expect(tester.terminalState, containsText('› One @today'));
        await tester.sendKey(LogicalKey.arrowDown);
        await pumpUntilText(tester, '› Two @today');
        expect(tester.terminalState, containsText('  One @today'));
        await tester.sendKey(LogicalKey.arrowDown);
        await tester.pump();
        expect(tester.terminalState, containsText('› Two @today'));
      }, size: size);
    });

    test('Ctrl+D completes the selected task and the cursor stays', () async {
      await testNocterm('complete', (tester) async {
        final container = await pumpTwo(tester);
        await tester.sendKey(LogicalKey.arrowDown);
        await pumpUntilText(tester, '› Two @today');
        await tester.sendKeyEvent(ctrlD);
        await pumpUntilText(tester, 'done: Two');
        expect(tester.terminalState, isNot(containsText('Two @today')));
        expect(tester.terminalState, containsText('› One @today'));
        final line = archiveLines(container).last;
        final json = jsonDecode(line) as Map<String, Object?>;
        expect(json['type'], 'task.complete');
        expect(json['actor'], 'user');
        expect(json['source'], EventSources.tui);
        expect(
          container
              .read(tasksProvider)
              .value!
              .list(TaskList.logbook, today: container.read(todayProvider))
              .single
              .title,
          'Two',
        );
      }, size: size);
    });

    test(
      'Ctrl+U after a completion puts the task back under the cursor',
      () async {
        await testNocterm('complete undo', (tester) async {
          await pumpTwo(tester);
          await tester.sendKey(LogicalKey.arrowDown);
          await pumpUntilText(tester, '› Two @today');
          await tester.sendKeyEvent(ctrlD);
          await pumpUntilText(tester, 'done: Two');
          await tester.sendKeyEvent(ctrlU);
          await pumpUntilText(tester, '› Two @today');
          expect(tester.terminalState, containsText('  One @today'));
        }, size: size);
      },
    );

    test('Ctrl+D with no task says so', () async {
      await testNocterm('complete nothing', (tester) async {
        await pumpTui(tester);
        await tester.sendKeyEvent(ctrlD);
        await pumpUntilText(tester, 'nothing selected');
      }, size: size);
    });

    test("another process's append shows up within the poll", () async {
      await testNocterm('follow', (tester) async {
        final container = await pumpTwo(tester);
        final root = container.read(archiveRootProvider);
        final other = await Archive.open(root);
        final store = await TaskStore.open(other, source: EventSources.app);
        await store.createTask(
          title: 'From the app',
          when: TaskWhen.date(container.read(todayProvider)),
        );
        store.dispose();
        await other.close();
        await pumpUntilText(
          tester,
          'From the app @today',
          timeout: _TuiAppPoll.twice,
        );
        expect(tester.terminalState, containsText('Today (3)'));
        expect(tester.terminalState, containsText('› One @today'));
      }, size: size);
    });

    test('Ctrl+D in the chat pane completes nothing', () async {
      await testNocterm('chat ctrl-d', (tester) async {
        final container = await pumpTwo(tester);
        await tester.sendKey(LogicalKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(ctrlD);
        await pumpFor(tester, const Duration(milliseconds: 100));
        expect(tester.terminalState, containsText('Today (2)'));
        expect(tester.terminalState, isNot(containsText('done:')));
        expect(
          container
              .read(tasksProvider)
              .value!
              .list(TaskList.logbook, today: container.read(todayProvider))
              .length,
          0,
        );
      }, size: size);
    });

    test('↑ after completing the last task moves from the marker', () async {
      await testNocterm('stale cursor', (tester) async {
        final container = await pumpTwo(tester);
        final store = container.read(tasksProvider.notifier).store;
        await store.createTask(
          title: 'Three',
          when: TaskWhen.date(container.read(todayProvider)),
        );
        await pumpUntilText(tester, 'Three @today');
        await tester.sendKey(LogicalKey.arrowDown);
        await tester.sendKey(LogicalKey.arrowDown);
        await pumpUntilText(tester, '› Three @today');
        await tester.sendKeyEvent(ctrlD);
        await pumpUntilText(tester, 'done: Three');
        expect(tester.terminalState, containsText('› Two @today'));
        await tester.sendKey(LogicalKey.arrowUp);
        await pumpUntilText(tester, '› One @today');
        expect(tester.terminalState, containsText('  Two @today'));
      }, size: size);
    });

    test('arrows in the chat pane leave the cursor alone', () async {
      await testNocterm('chat arrows', (tester) async {
        await pumpTwo(tester);
        await tester.sendKey(LogicalKey.tab);
        await tester.pump();
        await tester.sendKey(LogicalKey.arrowDown);
        await pumpFor(tester, const Duration(milliseconds: 100));
        expect(tester.terminalState, containsText('› One @today'));
        expect(tester.terminalState, isNot(containsText('› Two')));
      }, size: size);
    });
  });

  group('the chat (#34)', () {
    const big = Size(80, 24);

    Future<ProviderContainer> pumpChat(
      NoctermTester tester,
      FakeLlmProvider fake, {
      String? select = 'fake',
    }) async {
      // Provider and fixture first, one frame after: the fake's tag and
      // the list then render together rather than reflowing mid-pump.
      final container = testContainer(
        overrides: [
          builtinLlmsProvider.overrideWithValue([() => fake]),
        ],
      );
      await container.read(tasksProvider.future);
      await container
          .read(tasksProvider.notifier)
          .store
          .createTask(
            title: 'Call mom',
            when: TaskWhen.date(container.read(todayProvider)),
          );
      if (select != null) {
        container.read(settingsProvider.notifier).selectLlm(select);
      }
      await tester.pumpComponent(
        RiverpodScope(
          container: container,
          child: TuiApp(onQuit: () {}),
        ),
      );
      await pumpUntilText(tester, 'Call mom @today');
      return container;
    }

    Future<void> ask(NoctermTester tester, String line) async {
      await tester.sendKey(LogicalKey.tab);
      await tester.pump();
      await tester.enterText(line);
      await tester.sendEnter();
    }

    test('the pane is a line until it is used', () async {
      await testNocterm('collapsed', (tester) async {
        await pumpTui(tester);
        expect(tester.terminalState, containsText(chatPlaceholder));
        expect(
          tester.terminalState,
          isNot(containsText('Ask about your list')),
        );
        await tester.sendKey(LogicalKey.tab);
        await tester.pump();
        expect(tester.terminalState, containsText('Ask about your list'));
        // Typing now goes to the chat field, not capture.
        await tester.enterText('hello');
        await tester.pump();
        expect(tester.terminalState, containsText('hello'));
        expect(tester.terminalState, containsText('Capture to Inbox'));
      }, size: big);
    });

    test('Tab is one-way and Esc leads back when idle', () async {
      await testNocterm('keys', (tester) async {
        await pumpTui(tester);
        await tester.sendKey(LogicalKey.tab);
        await tester.sendKey(LogicalKey.tab);
        await tester.pump();
        // A doubled Tab still lands in the chat, not back in capture.
        await tester.enterText('hello');
        await tester.pump();
        expect(tester.terminalState, containsText('Capture to Inbox'));
        expect(tester.terminalState, containsText('hello'));
        await tester.sendKey(LogicalKey.escape);
        await tester.pump();
        await tester.enterText('milk');
        await tester.pump();
        // Esc when nothing runs: the capture field has focus again.
        expect(tester.terminalState, isNot(containsText('Capture to Inbox')));
        expect(tester.terminalState, containsText('milk'));
      }, size: big);
    });

    test('a question streams its answer, then settles', () async {
      await testNocterm('stream', (tester) async {
        final container = await pumpChat(
          tester,
          FakeLlmProvider(
            script: (_) => 'alpha beta gamma delta',
            delta: const Duration(milliseconds: 40),
          ),
        );
        await ask(tester, 'what is due?');
        await pumpUntilText(tester, 'you › what is due?');
        await pumpUntilText(tester, 'alpha beta');
        expect(
          tester.terminalState,
          isNot(containsText('delta')),
          reason: 'tokens must render as they arrive, not at the end',
        );
        expect(tester.terminalState, containsText('▌'));
        await pumpUntilText(tester, 'sai › alpha beta gamma delta');
        await pumpFor(tester, const Duration(milliseconds: 100));
        expect(tester.terminalState, isNot(containsText('▌')));
        expect(tester.terminalState, containsText(chatPlaceholder));
        final types = [
          for (final line in archiveLines(container))
            (jsonDecode(line) as Map)['type'],
        ];
        expect(types, [
          'task.create',
          'chat.message',
          'provider.request',
          'provider.response',
          'provider.usage',
          'chat.message',
        ]);
      }, size: big);
    });

    test('the model saw the list', () async {
      await testNocterm('context', (tester) async {
        await pumpChat(
          tester,
          FakeLlmProvider(
            script: (r) => r.messages
                .where((m) => m.text.contains('Call mom'))
                .map((m) => 'saw ${m.role.name}')
                .join(','),
          ),
        );
        await ask(tester, 'due?');
        await pumpUntilText(tester, 'sai › saw system');
      }, size: big);
    });

    test('reasoning shows only with the setting on', () async {
      await testNocterm('reasoning', (tester) async {
        final container = await pumpChat(
          tester,
          FakeLlmProvider(
            script: (_) => 'ready.',
            reasoning: (_) => 'let me think',
          ),
        );
        await ask(tester, 'go');
        await pumpUntilText(tester, 'sai › ready.');
        expect(tester.terminalState, isNot(containsText('let me think')));
        container.read(settingsProvider.notifier).setReasoning(true);
        await tester.enterText('again');
        await tester.sendEnter();
        await pumpUntilText(tester, 'sai thinks › let me think');
      }, size: big);
    });

    test('Esc stops a slow answer and keeps the part that came', () async {
      await testNocterm('cancel', (tester) async {
        await pumpChat(
          tester,
          FakeLlmProvider(
            script: (_) => List.filled(100, 'x').join(' '),
            delta: const Duration(milliseconds: 30),
          ),
        );
        await ask(tester, 'go');
        await pumpUntilText(tester, 'x x');
        await tester.sendKey(LogicalKey.escape);
        await pumpUntilText(tester, 'sai · cancelled › x');
        expect(tester.terminalState, isNot(containsText('▌')));
      }, size: big);
    });

    test('a failed call is named', () async {
      await testNocterm('failure', (tester) async {
        await pumpChat(
          tester,
          FakeLlmProvider(
            failWith: const LlmFailure(
              LlmFailureKind.unreachable,
              'nothing answered at the endpoint',
              endpoint: 'http://localhost:1',
            ),
          ),
        );
        await ask(tester, 'go');
        await pumpUntilText(
          tester,
          'failed: unreachable — nothing answered at the endpoint',
        );
      }, size: big);
    });

    test(
      'a cloud provider with sharing off says the tasks are withheld',
      () async {
        await testNocterm('withheld', (tester) async {
          await pumpChat(
            tester,
            FakeLlmProvider(
              id: 'cloudy',
              privacy: LlmPrivacy.cloud,
              script: (r) => r.messages.any((m) => m.text.contains('Call mom'))
                  ? 'saw it'
                  : 'blind',
            ),
            select: 'cloudy',
          );
          await pumpUntilText(tester, tasksWithheldSuffix);
          await ask(tester, 'due?');
          await pumpUntilText(tester, 'sai · tasks withheld › blind');
        }, size: big);
      },
    );

    test('without a provider the send is refused and the line kept', () async {
      await testNocterm('no provider', (tester) async {
        await pumpChat(tester, FakeLlmProvider(), select: null);
        await ask(tester, 'anyone?');
        await pumpUntilText(tester, noProviderStatus);
        expect(tester.terminalState, containsText('anyone?'));
      }, size: big);
    });
  });

  test('pubspec version matches saiVersion', () async {
    final lib = await Isolate.resolvePackageUri(
      Uri.parse('package:sai_tui/tui_app.dart'),
    );
    final root = File.fromUri(lib!).parent.parent;
    final pubspec = loadYaml(
      File('${root.path}/pubspec.yaml').readAsStringSync(),
    ) as YamlMap;
    expect(pubspec['version'], saiVersion);
  });
}

class _StuckTasks extends TasksNotifier {
  @override
  Future<TaskProjection> build() => Completer<TaskProjection>().future;
}

class _FailingTasks extends TasksNotifier {
  @override
  Future<TaskProjection> build() async {
    throw StateError('no archive today');
  }
}

abstract final class _TuiAppPoll {
  static const twice = Duration(seconds: 5);
}

class _TestToday extends TodayNotifier {
  @override
  CalendarDate build() => const CalendarDate(2026, 8, 24);

  void advance() => state = const CalendarDate(2026, 8, 25);
}
