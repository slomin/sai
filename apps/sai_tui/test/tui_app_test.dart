import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
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
