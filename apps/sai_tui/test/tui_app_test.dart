import 'dart:io';
import 'dart:isolate';

import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:sai_tui/tui_app.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// `testNocterm` is a plain async function, not a `test` registration, and
/// nocterm allows one binding at a time — so each call is wrapped in a
/// `test` and awaited.
void main() {
  test('shell shows the greeting from sai_core', () async {
    await testNocterm('greeting', (tester) async {
      final container = ProviderContainer.test();
      await tester.pumpComponent(
        RiverpodScope(
          container: container,
          child: TuiApp(onQuit: () {}),
        ),
      );
      expect(
        tester.terminalState,
        containsText('sai 2.0.0-dev — nothing here yet'),
      );
      expect(tester.terminalState, containsText('q quit'));
    }, size: const Size(60, 10));
  });

  test('shell reads through the shared provider layer', () async {
    await testNocterm('override', (tester) async {
      final container = ProviderContainer.test(
        overrides: [
          appInfoProvider.overrideWithValue(
            const AppInfo(name: 'override', version: '0'),
          ),
        ],
      );
      await tester.pumpComponent(
        RiverpodScope(
          container: container,
          child: TuiApp(onQuit: () {}),
        ),
      );
      expect(
        tester.terminalState,
        containsText('override 0 — nothing here yet'),
      );
    }, size: const Size(60, 10));
  });

  test('q and Ctrl+C quit; Alt+Q and other keys do not', () async {
    await testNocterm('quit keys', (tester) async {
      var quits = 0;
      final container = ProviderContainer.test();
      await tester.pumpComponent(
        RiverpodScope(
          container: container,
          child: TuiApp(onQuit: () => quits++),
        ),
      );

      await tester.sendKey(LogicalKey.keyX);
      await tester.sendKeyEvent(
        KeyboardEvent(
          logicalKey: LogicalKey.keyQ,
          modifiers: const ModifierKeys(alt: true),
        ),
      );
      await tester.pump();
      expect(quits, 0);

      await tester.sendKey(LogicalKey.keyQ);
      await tester.pump();
      expect(quits, 1);

      await tester.sendKeyEvent(
        KeyboardEvent(
          logicalKey: LogicalKey.keyC,
          modifiers: const ModifierKeys(ctrl: true),
        ),
      );
      await tester.pump();
      expect(quits, 2);
    }, size: const Size(60, 10));
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
