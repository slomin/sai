import 'package:nocterm/nocterm.dart';
import 'package:nocterm_spike/spike_app.dart';
import 'package:test/test.dart';

/// nocterm 0.9.0's `pumpAndSettle` never settles (it counts the frame it
/// pumps itself as "a change"), so pump a fixed number of real-time frames.
Future<void> pumpFor(NoctermTester tester, Duration total,
    {Duration step = const Duration(milliseconds: 10)}) async {
  var elapsed = Duration.zero;
  while (elapsed < total) {
    await tester.pump(step);
    elapsed += step;
  }
}

/// Pump real-time frames until [text] is on screen or [timeout] passes.
Future<void> pumpUntilText(NoctermTester tester, String text,
    {Duration timeout = const Duration(seconds: 2)}) async {
  var elapsed = Duration.zero;
  const step = Duration(milliseconds: 5);
  while (!tester.terminalState.containsText(text)) {
    if (elapsed >= timeout) {
      fail('"$text" did not appear within $timeout');
    }
    await tester.pump(step);
    elapsed += step;
  }
}

void main() {
  test('list and chat render side by side', () async {
    await testNocterm('initial layout', (tester) async {
      await tester.pumpComponent(const SpikeApp());
      expect(tester.terminalState, containsText('▶  1  Bootstrap'));
      expect(tester.terminalState, containsText('Ask sai'));
      expect(tester.terminalState, containsText('focus:list'));
    }, size: const Size(100, 30));
  });

  test('vim and arrow keys move the selection and keep it visible', () async {
    await testNocterm('navigation', (tester) async {
      await tester.pumpComponent(const SpikeApp());
      await tester.sendKey(LogicalKey.keyJ);
      await tester.sendKey(LogicalKey.keyJ);
      await tester.sendArrowDown();
      expect(tester.terminalState, containsText('▶  4  Provision'));
      expect(tester.terminalState, isNot(containsText('▶  1')));

      await tester.sendKeyEvent(const KeyboardEvent(
        logicalKey: LogicalKey.keyG,
        character: 'G',
        modifiers: ModifierKeys(shift: true),
      ));
      expect(tester.terminalState, containsText('▶ 30  Sign and notarize'));
      expect(tester.terminalState, isNot(containsText(' 1  Bootstrap')),
          reason: 'list must scroll so the last item is visible');

      await tester.sendKey(LogicalKey.keyG);
      await tester.sendKey(LogicalKey.keyK); // clamps at 0
      expect(tester.terminalState, containsText('▶  1  Bootstrap'));
    }, size: const Size(100, 20));
  });

  test('a reply streams token by token while the list stays put', () async {
    await testNocterm('streaming', (tester) async {
      await tester.pumpComponent(const SpikeApp(
        reply: 'alpha beta gamma delta',
        tokenGap: Duration(milliseconds: 60),
      ));
      await tester.sendKey(LogicalKey.keyJ);
      await tester.sendEnter(); // asks about the selected task
      expect(tester.terminalState, containsText('What should I do about'));
      expect(tester.terminalState, containsText('about "Define the'),
          reason: 'the row number is presentation, not part of the task');

      await pumpUntilText(tester, 'alpha beta');
      expect(tester.terminalState, isNot(containsText('delta')),
          reason: 'tokens must render as they arrive, not at the end');
      expect(tester.terminalState, containsText('streaming'));

      await pumpUntilText(tester, 'alpha beta gamma delta');
      await tester.pump(const Duration(milliseconds: 20)); // onDone frame
      expect(tester.terminalState, isNot(containsText('streaming')));
      expect(tester.terminalState, containsText('tokens:4'));
      expect(tester.terminalState, containsText('▶  2  Define'));
    }, size: const Size(100, 30));
  });

  test('the input takes UTF-8 and multi-line text', () async {
    await testNocterm('utf8 multiline', (tester) async {
      await tester.pumpComponent(const SpikeApp(
        reply: 'ok',
        tokenGap: Duration(milliseconds: 1),
      ));
      await tester.sendTab();
      expect(tester.terminalState, containsText('focus:chat'));

      await tester.enterText('żółć 🚀 pierwsza linia');
      await tester.sendKeyEvent(const KeyboardEvent(
        logicalKey: LogicalKey.keyJ,
        modifiers: ModifierKeys(ctrl: true),
      ));
      await tester.enterText('druga linia');
      expect(tester.terminalState, containsText('żółć 🚀 pierwsza linia'));
      expect(tester.terminalState, containsText('druga linia'));

      await tester.sendEnter();
      await pumpFor(tester, const Duration(milliseconds: 50));
      expect(tester.terminalState, containsText('you'));
      expect(tester.terminalState, containsText('żółć 🚀 pierwsza linia'));
      expect(tester.terminalState, containsText('druga linia'));
      expect(tester.terminalState, containsText('sai'));
    }, size: const Size(100, 30));
  });

  test(
      'a draft survives asking from the list, and sends are refused while '
      'streaming', () async {
    await testNocterm('draft and busy', (tester) async {
      await tester.pumpComponent(const SpikeApp(
        reply: 'one two three four five six',
        tokenGap: Duration(milliseconds: 40),
      ));
      await tester.sendTab();
      await tester.enterText('half written draft');
      await tester.sendTab();
      expect(tester.terminalState, containsText('focus:list'));
      await tester.sendEnter(); // ask about task 1 from the list
      expect(tester.terminalState, containsText('half written draft'),
          reason: 'asking from the list must not clear the chat draft');

      await tester.sendTab();
      await tester.sendEnter(); // try to send the draft mid-stream
      expect(tester.terminalState, containsText('busy'));
      expect(tester.terminalState, containsText('half written draft'),
          reason: 'a refused send keeps the text in the input');

      await pumpUntilText(tester, 'one two three four five six');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.sendEnter();
      await tester.pump();
      expect(tester.terminalState, isNot(containsText('busy')));
      expect(tester.terminalState, containsText('you'));
    }, size: const Size(100, 30));
  });

  test('modified q does not quit (shutdownApp would throw under the tester)',
      () async {
    await testNocterm('modified q', (tester) async {
      await tester.pumpComponent(const SpikeApp());
      await tester.sendKeyEvent(const KeyboardEvent(
        logicalKey: LogicalKey.keyQ,
        character: 'Q',
        modifiers: ModifierKeys(shift: true),
      ));
      await tester.sendKeyEvent(const KeyboardEvent(
        logicalKey: LogicalKey.keyQ,
        modifiers: ModifierKeys(alt: true),
      ));
      expect(tester.terminalState, containsText('focus:list'));
    }, size: const Size(100, 20));
  });
}
