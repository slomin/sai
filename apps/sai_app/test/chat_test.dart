import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/chat_pane.dart';
import 'package:sai_app/commands.dart';
import 'package:sai_app/main_pane.dart';
import 'package:sai_app/sidebar.dart';
import 'package:sai_app/shell.dart';
import 'package:sai_core/sai_core.dart';

import 'harness.dart';
import 'stub_server.dart';

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
  // Chords are asserted under the platform the app ships on: the default
  // test platform (android) binds a different key map.
  final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

  // Sizes the window the way the app sees it: `MediaQuery` reads the
  // view, not the test surface, so the breakpoints must be driven there.
  Future<void> surface(WidgetTester tester, double width) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
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
  }, variant: macOS);

  testWidgets('Cmd+J in a window too narrow for the chat says so', (
    tester,
  ) async {
    await surface(tester, 700);
    final container = await pumpApp(tester);
    expect(chatFits(tester.element(find.byKey(captureFieldKey))), isFalse);
    await chord(tester, LogicalKeyboardKey.keyJ);
    expect(container.read(chatVisibleProvider), isTrue);
    expect(find.textContaining('widen the window'), findsOneWidget);
    final item = menuItem(menuDelegate.menus, ['View', 'Show Chat']);
    expect(item.onSelected, isNull);
    // Nothing latched: widening shows the chat without stealing focus.
    tester.view.physicalSize = const Size(900, 600);
    await tester.pump();
    await tester.pump();
    expect(find.byType(ChatPane), findsOneWidget);
    expect(container.read(chatFocusProvider).hasFocus, isFalse);
    expect(container.read(captureFocusProvider).hasFocus, isTrue);
    expect(
      menuItem(menuDelegate.menus, ['View', 'Hide Chat']).onSelected,
      isNotNull,
    );
  }, variant: macOS);

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
  }, variant: macOS);

  testWidgets('a narrow window drops the chat pane, a narrower the sidebar', (
    tester,
  ) async {
    await surface(tester, 700);
    final container = await pumpApp(tester);
    expect(container.read(chatVisibleProvider), isTrue);
    expect(find.byType(ChatPane), findsNothing);
    expect(find.byType(SaiSidebar), findsOneWidget);
    expect(find.byKey(captureFieldKey), findsOneWidget);

    tester.view.physicalSize = const Size(500, 600);
    await tester.pump();
    expect(find.byType(SaiSidebar), findsNothing);
    expect(find.byKey(captureFieldKey), findsOneWidget);

    tester.view.physicalSize = const Size(900, 600);
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

    tester.view.physicalSize = const Size(500, 600);
    await tester.pump();
    expect(find.byType(SaiSidebar), findsNothing);
    tester.view.physicalSize = const Size(900, 600);
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
        llmStatusProvider.overrideWithValue(
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

  testWidgets('the status bar follows the selected provider', (tester) async {
    final container = await pumpApp(tester);
    container.read(settingsProvider.notifier).selectLlm('fake');
    await tester.pump();
    expect(find.text('fake (fake-1) — local'), findsOneWidget);
    expect(find.text(noProviderStatus), findsNothing);
  });

  group('the conversation (#34)', () {
    late FakeLlmProvider fake;

    setUp(() => fake = FakeLlmProvider(script: echo));

    Future<ProviderContainer> ready(
      WidgetTester tester, {
      String select = 'fake',
    }) async {
      final container = await pumpApp(
        tester,
        overrides: [
          builtinLlmsProvider.overrideWithValue([() => fake]),
        ],
      );
      await tester.runAsync(
        () => container
            .read(tasksProvider.notifier)
            .store
            .createTask(
              title: 'Call mom',
              when: TaskWhen.date(container.read(todayProvider)),
            ),
      );
      container.read(settingsProvider.notifier).selectLlm(select);
      await tester.pump();
      return container;
    }

    Future<void> ask(WidgetTester tester, String line) async {
      await tester.enterText(find.byKey(chatFieldKey), line);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
    }

    testWidgets('a question streams its answer into the pane', (tester) async {
      final container = await ready(tester);
      await ask(tester, 'what is due?');
      await until(tester, () => container.read(chatProvider).turns.length == 2);
      expect(find.byKey(chatSendKey), findsOneWidget);
      // The pane followed the answer; the question is above the fold.
      await tester.drag(find.byKey(chatTranscriptKey), const Offset(0, 5000));
      await tester.pump();
      expect(find.text('what is due?'), findsOneWidget, reason: screen());
      expect(find.text('you'), findsOneWidget);
      // The fake echoed what it saw: the list was in the context.
      expect(
        find.descendant(
          of: find.byKey(chatTranscriptKey),
          matching: find.textContaining('Call mom @today'),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(find.byKey(chatFieldKey)).controller!.text,
        '',
      );
      final log = archiveLines(container.read(archiveRootProvider));
      expect(log.where((l) => l.contains('"chat.message"')), hasLength(2));
      expect(log.where((l) => l.contains('"provider.request"')), hasLength(1));
      expect(
        log.singleWhere((l) => l.contains('"provider.request"')),
        contains('"context_hash":"sha256-'),
      );
    });

    testWidgets('Stop cancels a slow answer', (tester) async {
      fake = FakeLlmProvider(
        script: (_) => List.filled(200, 'x').join(' '),
        delta: const Duration(milliseconds: 20),
      );
      final container = await ready(tester);
      await ask(tester, 'go');
      await until(
        tester,
        () => find.textContaining('x x').evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(chatStopKey));
      await until(tester, () => container.read(chatProvider).turns.length == 2);
      expect(find.text('sai · cancelled'), findsOneWidget);
      expect(find.byKey(chatSendKey), findsOneWidget);
    });

    testWidgets('Esc stops the answer too', (tester) async {
      fake = FakeLlmProvider(
        script: (_) => List.filled(200, 'x').join(' '),
        delta: const Duration(milliseconds: 20),
      );
      final container = await ready(tester);
      await ask(tester, 'go');
      await until(
        tester,
        () => find.textContaining('x x').evaluate().isNotEmpty,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await until(tester, () => container.read(chatProvider).turns.length == 2);
      expect(find.text('sai · cancelled'), findsOneWidget);
    }, variant: macOS);

    testWidgets('a failed call is named by kind, message and origin', (
      tester,
    ) async {
      fake = FakeLlmProvider(
        failWith: const LlmFailure(
          LlmFailureKind.unreachable,
          'nothing answered at the endpoint',
          endpoint: 'http://localhost:1',
        ),
      );
      final container = await ready(tester);
      await ask(tester, 'go');
      await until(tester, () => container.read(chatProvider).turns.length == 2);
      expect(
        find.text(
          'failed: unreachable — nothing answered at the endpoint '
          '(http://localhost:1)',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a cloud provider with sharing off answers without the list', (
      tester,
    ) async {
      fake = FakeLlmProvider(
        id: 'cloudy',
        privacy: LlmPrivacy.cloud,
        script: echo,
      );
      final container = await ready(tester, select: 'cloudy');
      expect(find.textContaining(tasksWithheldSuffix), findsOneWidget);
      await ask(tester, 'due?');
      await until(tester, () => container.read(chatProvider).turns.length == 2);
      expect(find.text('sai · tasks withheld'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(chatTranscriptKey),
          matching: find.textContaining('Call mom'),
        ),
        findsNothing,
      );
      final log = archiveLines(container.read(archiveRootProvider));
      expect(log.where((l) => l.contains('"policy.decision"')), hasLength(1));
    });

    testWidgets('⌘R shows and hides the reasoning, and remembers it', (
      tester,
    ) async {
      fake = FakeLlmProvider(
        script: (_) => 'ready.',
        reasoning: (_) => 'let me think',
      );
      final container = await ready(tester);
      await ask(tester, 'go');
      await until(tester, () => container.read(chatProvider).turns.length == 2);
      expect(find.byKey(chatReasoningKey), findsNothing);
      expect(find.text('ready.'), findsOneWidget);
      await chord(tester, LogicalKeyboardKey.keyR);
      expect(find.byKey(chatReasoningKey), findsOneWidget);
      expect(find.text('let me think'), findsOneWidget);
      expect(find.text('reasoning shown'), findsOneWidget);
      expect(container.read(settingsProvider).showReasoning, isTrue);
      expect(
        menuItem(menuDelegate.menus, ['View', 'Hide Reasoning']),
        isNotNull,
      );
      await chord(tester, LogicalKeyboardKey.keyR);
      expect(find.byKey(chatReasoningKey), findsNothing);
      expect(container.read(settingsProvider).showReasoning, isFalse);
    }, variant: macOS);

    testWidgets('a refused send keeps the draft and says why', (tester) async {
      final container = await ready(tester);
      container.read(settingsProvider.notifier).selectLlm(null);
      await tester.pump();
      await ask(tester, 'anyone there?');
      expect(find.text(noProviderStatus), findsNWidgets(2));
      expect(
        tester.widget<TextField>(find.byKey(chatFieldKey)).controller!.text,
        'anyone there?',
      );
      expect(container.read(chatProvider).turns, isEmpty);
    });
  });

  group('against a stub endpoint', () {
    late StubServer stub;
    HttpOverrides? blocked;
    setUp(() async {
      blocked = HttpOverrides.current;
      HttpOverrides.global = null;
      stub = await StubServer.start();
    });
    tearDown(() async {
      await stub.close();
      HttpOverrides.global = blocked;
    });

    testWidgets('one turn goes over the wire and is hashed', (tester) async {
      stub.words = const ['Call ', 'mom ', 'is ', 'due.'];
      final container = await pumpApp(tester);
      final settings = container.read(settingsProvider.notifier);
      settings.upsertProvider(
        ProviderConfig(
          id: 'local',
          kind: 'openai_compatible',
          endpoint: stub.v1,
          defaultModel: 'qwen',
        ),
      );
      settings.selectLlm('local');
      await tester.pump();
      await tester.enterText(find.byKey(chatFieldKey), 'what is due?');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await until(tester, () => container.read(chatProvider).turns.length == 2);
      expect(find.textContaining('Call mom is due.'), findsOneWidget);
      expect(stub.requests, contains('POST /v1/chat/completions'));
      final log = archiveLines(container.read(archiveRootProvider));
      final request = log.singleWhere((l) => l.contains('"provider.request"'));
      expect(request, contains('"context_hash":"sha256-'));
      expect(request, contains(defaultProfile.split('\n').first));
      final said = log.last;
      expect(said, contains('"chat.message"'));
      expect(said, contains('"actor":"assistant"'));
      expect(said, contains('"finish":"stop"'));
      await container.read(llmRegistryProvider)['local']!.close();
      await tester.pump();
    });
  });
}

String screen() => find
    .byType(Text)
    .evaluate()
    .map((e) => (e.widget as Text).data)
    .join(' / ');

/// A fake that answers with what it was shown, so a test can see whether
/// the list reached the model.
String echo(LlmRequest r) =>
    r.messages.map((m) => '${m.role.name}:${m.text}').join(' | ');

/// Pumps until [ready]: the archive writes are real I/O (hence
/// `runAsync`) while the fake's delays are timers on the test clock
/// (hence pumping with a duration) — both have to move.
Future<void> until(
  WidgetTester tester,
  bool Function() ready, {
  Duration timeout = const Duration(seconds: 10),
}) => tester.runAsync(() async {
  final deadline = DateTime.now().add(timeout);
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'timed out — ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).join(' / ')}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
  }
  // One more frame so the screen shows the state that satisfied [ready].
  await tester.pump();
});
