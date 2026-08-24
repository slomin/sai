import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/chat_pane.dart';
import 'package:sai_app/commands.dart';
import 'package:sai_app/main_pane.dart';
import 'package:sai_app/sidebar.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';

Future<void> chord(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  // One frame to rebuild, one more for a post-frame focus request.
  await tester.pump();
  await tester.pump();
}

void main() {
  Future<void> surface(WidgetTester tester, double width) async {
    await tester.binding.setSurfaceSize(Size(width, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets('the chat pane shows by default with a placeholder', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.byType(ChatPane), findsOneWidget);
    expect(find.byKey(chatFieldKey), findsOneWidget);
    expect(find.textContaining('assistant'), findsOneWidget);
  });

  testWidgets('Cmd+J hides the chat, then shows it and focuses it', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    await chord(tester, LogicalKeyboardKey.keyJ);
    expect(find.byType(ChatPane), findsNothing);
    expect(container.read(chatVisibleProvider), isFalse);

    await chord(tester, LogicalKeyboardKey.keyJ);
    expect(find.byType(ChatPane), findsOneWidget);
    expect(container.read(chatFocusProvider).hasFocus, isTrue);
    expect(container.read(captureFocusProvider).hasFocus, isFalse);
  });

  testWidgets('Cmd+N brings focus back to quick capture', (tester) async {
    final container = await pumpApp(tester);
    await tester.tap(find.byKey(chatFieldKey));
    await tester.pump();
    expect(container.read(chatFocusProvider).hasFocus, isTrue);

    await chord(tester, LogicalKeyboardKey.keyN);
    expect(container.read(captureFocusProvider).hasFocus, isTrue);
    expect(
      tester.widget<TextField>(find.byKey(captureFieldKey)).focusNode,
      same(container.read(captureFocusProvider)),
    );
  });

  testWidgets('a narrow window drops the chat pane, a narrower the sidebar', (
    tester,
  ) async {
    await surface(tester, 700);
    final container = await pumpApp(tester);
    expect(container.read(chatVisibleProvider), isTrue);
    expect(find.byType(ChatPane), findsNothing);
    expect(find.byType(SaiSidebar), findsOneWidget);
    expect(find.byKey(captureFieldKey), findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(500, 600));
    await tester.pump();
    expect(find.byType(SaiSidebar), findsNothing);
    expect(find.byKey(captureFieldKey), findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(900, 600));
    await tester.pump();
    expect(find.byType(SaiSidebar), findsOneWidget);
    expect(find.byType(ChatPane), findsOneWidget);
  });

  testWidgets('typed text survives resizing across the breakpoints', (
    tester,
  ) async {
    await surface(tester, 900);
    await pumpApp(tester);
    await tester.enterText(find.byKey(captureFieldKey), 'half a thought');
    await tester.enterText(find.byKey(chatFieldKey), 'hi');
    await tester.pump();

    await tester.binding.setSurfaceSize(const Size(500, 600));
    await tester.pump();
    expect(find.byType(SaiSidebar), findsNothing);
    await tester.binding.setSurfaceSize(const Size(900, 600));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byKey(captureFieldKey)).controller!.text,
      'half a thought',
    );
    expect(
      tester.widget<TextField>(find.byKey(chatFieldKey)).controller!.text,
      'hi',
    );
  });

  testWidgets('the status bar fits a long provider line and a long notice', (
    tester,
  ) async {
    await surface(tester, 500);
    final container = await pumpApp(
      tester,
      overrides: [
        providerStatusProvider.overrideWithValue(
          'openai-compatible @ http://192.168.1.20:8080 (llama-3.3-70b) — cloud',
        ),
      ],
    );
    // No RenderFlex overflow is the assertion: flutter_test fails on one.
    container.read(noticeProvider.notifier).show('undo failed: ${'x' * 200}');
    await tester.pump();
    expect(find.textContaining('undo failed:'), findsOneWidget);
  });

  testWidgets('a notice gets the row, not a fixed half of it', (tester) async {
    await surface(tester, 900);
    final container = await pumpApp(tester);
    container.read(noticeProvider.notifier).show('undo failed: ${'x' * 200}');
    await tester.pump();
    expect(
      tester.getSize(find.textContaining('undo failed:')).width,
      greaterThan(500),
    );
  });

  testWidgets('the status bar names the (missing) provider', (tester) async {
    await pumpApp(tester);
    expect(find.text(noProviderStatus), findsOneWidget);
    expect(find.text('no provider — local only'), findsOneWidget);
  });

  testWidgets('submitting in the chat field says it is not wired up', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.enterText(find.byKey(chatFieldKey), 'hello?');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.textContaining('chat is not wired up'), findsOneWidget);
  });
}
