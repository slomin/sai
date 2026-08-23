import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:sai_tui/tui_app.dart';
import 'package:test/test.dart';

/// `testNocterm` is a plain async function, not a `test` registration, and
/// nocterm allows one binding at a time — so each call is wrapped in a
/// `test` and awaited.
void main() {
  test('shell shows the greeting from sai_core', () async {
    await testNocterm('greeting', (tester) async {
      final container = ProviderContainer.test();
      await tester.pumpComponent(
        RiverpodScope(container: container, child: const TuiApp()),
      );
      expect(
        tester.terminalState,
        containsText('sai $saiVersion — nothing here yet'),
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
        RiverpodScope(container: container, child: const TuiApp()),
      );
      expect(
        tester.terminalState,
        containsText('override 0 — nothing here yet'),
      );
    }, size: const Size(60, 10));
  });
}
