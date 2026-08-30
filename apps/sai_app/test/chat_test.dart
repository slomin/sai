import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/assistant/assistant_band.dart';
import 'package:sai_app/assistant/markdown/code_block.dart';
import 'package:sai_app/assistant/waiting_dots.dart';
import 'package:sai_app/commands.dart';
import 'package:sai_app/workspace/task_list_pane.dart';
import 'package:sai_app/sidebar.dart';
import 'package:sai_app/theme/sai_tokens.dart';
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

  testWidgets('the assistant band opens by default with a placeholder', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.byType(AssistantBand), findsOneWidget);
    expect(find.byKey(chatFieldKey), findsOneWidget);
    expect(find.textContaining('assistant'), findsOneWidget);
  });

  testWidgets('Cmd+J tucks the band away, then opens it and focuses it', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    await chord(tester, LogicalKeyboardKey.keyJ);
    expect(find.byKey(chatFieldKey), findsNothing);
    expect(find.byKey(assistantHeaderKey), findsOneWidget);
    expect(container.read(chatVisibleProvider), isFalse);
    expect(container.read(captureFocusProvider).hasFocus, isTrue);

    await chord(tester, LogicalKeyboardKey.keyJ);
    expect(find.byKey(chatFieldKey), findsOneWidget);
    expect(container.read(chatFocusProvider).hasFocus, isTrue);
    expect(container.read(captureFocusProvider).hasFocus, isFalse);
  }, variant: macOS);

  testWidgets('the band header tucks the band away and brings it back', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    await tester.tap(find.byKey(assistantHeaderKey));
    await tester.pump();
    expect(container.read(chatVisibleProvider), isFalse);
    expect(find.byKey(chatFieldKey), findsNothing);
    await tester.tap(find.byKey(assistantHeaderKey));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(chatFieldKey), findsOneWidget);
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
  }, variant: macOS);

  testWidgets('a narrow window drops the sidebar; the band stays', (
    tester,
  ) async {
    await surface(tester, 700);
    await pumpApp(tester);
    expect(find.byType(SaiSidebar), findsOneWidget);
    expect(find.byKey(chatFieldKey), findsOneWidget);
    expect(find.byKey(captureFieldKey), findsOneWidget);

    tester.view.physicalSize = const Size(500, 600);
    await tester.pump();
    expect(find.byType(SaiSidebar), findsNothing);
    expect(find.byKey(captureFieldKey), findsOneWidget);
    expect(find.byKey(chatFieldKey), findsOneWidget);

    tester.view.physicalSize = const Size(900, 600);
    await tester.pump();
    expect(find.byType(SaiSidebar), findsOneWidget);
  });

  testWidgets('typed text survives resizing across the breakpoint', (
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

  testWidgets('the top bar and the band header fit long lines', (tester) async {
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

  testWidgets('a notice gets the room the bar has left', (tester) async {
    await surface(tester, 900);
    final container = await pumpApp(tester);
    container.read(noticeProvider.notifier).show('undo failed: ${'x' * 200}');
    await tester.pump();
    expect(
      tester.getSize(find.textContaining('undo failed:')).width,
      greaterThan(300),
    );
  });

  testWidgets('the band header names the (missing) provider', (tester) async {
    await pumpApp(tester);
    expect(find.text(noProviderStatus), findsOneWidget);
  });

  testWidgets('the band header follows the selected provider', (tester) async {
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
      bool reduceMotion = true,
    }) async {
      final container = await pumpApp(
        tester,
        builtins: [() => fake],
        reduceMotion: reduceMotion,
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
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
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
      // The top bar counts every line, the chat's included.
      await until(
        tester,
        () => find.text('ARCHIVE · ${log.length} LINES').evaluate().isNotEmpty,
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
      // The archive holds the cancelled turn, not only the pane (#39).
      final log = archiveLines(container.read(archiveRootProvider));
      expect(log.last, contains('"chat.message"'));
      expect(log.last, contains('"finish":"cancelled"'));
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

    testWidgets('⌘R lets the model think, shows it, and remembers it', (
      tester,
    ) async {
      fake = FakeLlmProvider(
        script: (_) => 'ready.',
        reasoning: (_) => 'let me think',
      );
      final container = await ready(tester);
      // Off by default: the request says so and nothing is shown.
      await ask(tester, 'go');
      await until(tester, () => container.read(chatProvider).turns.length == 2);
      expect(find.byKey(chatReasoningKey), findsNothing);
      expect(find.text('ready.'), findsOneWidget);
      expect(
        archiveLines(container.read(archiveRootProvider))
            .singleWhere((l) => l.contains('"provider.request"')),
        contains('"reasoning":false'),
      );
      await chord(tester, LogicalKeyboardKey.keyR);
      expect(find.text('reasoning on'), findsOneWidget);
      expect(container.read(settingsProvider).reasoningOn, isTrue);
      expect(
        menuItem(menuDelegate.menus, ['View', 'Disable Reasoning']),
        isNotNull,
      );
      await ask(tester, 'again');
      await until(tester, () => container.read(chatProvider).turns.length == 4);
      expect(find.byKey(chatReasoningKey), findsOneWidget);
      expect(find.text('let me think'), findsOneWidget);
      await chord(tester, LogicalKeyboardKey.keyR);
      expect(find.byKey(chatReasoningKey), findsNothing);
      expect(container.read(settingsProvider).reasoningOn, isFalse);
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

    group('the composer (#39)', () {
      testWidgets('Shift+Enter breaks the line and sends nothing', (
        tester,
      ) async {
        final container = await ready(tester);
        await tester.enterText(find.byKey(chatFieldKey), 'one');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(container.read(chatDraftProvider).text, 'one\n');
        expect(container.read(chatProvider).turns, isEmpty);
      });

      testWidgets('Option+Enter breaks the line too', (tester) async {
        final container = await ready(tester);
        await tester.enterText(find.byKey(chatFieldKey), 'one');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
        await tester.pump();
        expect(container.read(chatDraftProvider).text, 'one\n');
        expect(container.read(chatProvider).turns, isEmpty);
      });

      testWidgets('a multi-line draft goes out as one message', (tester) async {
        final container = await ready(tester);
        await tester.enterText(find.byKey(chatFieldKey), 'one\ntwo');
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await until(
          tester,
          () => container.read(chatProvider).turns.length == 2,
        );
        expect(container.read(chatProvider).turns.first.text, 'one\ntwo');
        expect(container.read(chatDraftProvider).text, '');
      });

      testWidgets('⌘⏎ stays a Task chord, not a send', (tester) async {
        final container = await ready(tester);
        await tester.enterText(find.byKey(chatFieldKey), 'one');
        await chord(tester, LogicalKeyboardKey.enter);
        expect(container.read(chatProvider).turns, isEmpty);
        expect(container.read(chatDraftProvider).text, 'one');
      }, variant: macOS);

      testWidgets('⌘V pastes a multi-line clipboard', (tester) async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => call.method == 'Clipboard.getData'
              ? <String, dynamic>{'text': 'one\ntwo'}
              : null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final container = await ready(tester);
        await tester.tap(find.byKey(chatFieldKey));
        await tester.pump();
        await chord(tester, LogicalKeyboardKey.keyV);
        await tester.pump();
        expect(container.read(chatDraftProvider).text, 'one\ntwo');
      }, variant: macOS);

      testWidgets('the caret is thin and light on the dark card', (
        tester,
      ) async {
        await ready(tester);
        final field = tester.widget<TextField>(find.byKey(chatFieldKey));
        expect(field.cursorColor, SaiColors.sheetText);
        expect(field.cursorWidth, 1.5);
        expect(field.cursorOpacityAnimates, isFalse);
      });

      testWidgets('a long draft never overflows the band', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(900, 420);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await ready(tester);
        await tester.enterText(
          find.byKey(chatFieldKey),
          List.generate(20, (i) => 'line $i').join('\n'),
        );
        await tester.pump();
        // No RenderFlex overflow is the assertion; the field scrolls.
        expect(find.byKey(chatFieldKey), findsOneWidget);
      });
    });

    testWidgets('a scaled, narrow, streaming transcript neither overflows '
        'nor jumps (#99)', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      fake = FakeLlmProvider(
        script: (_) =>
            '# Plan\n\nA **long** first paragraph that has to wrap more '
            'than once at this width and scale, and then some.\n\n'
            '```dart\nvoid main() { print("a line wide enough to scroll '
            'sideways in the card"); }\n```\n\nDone.',
        delta: const Duration(milliseconds: 20),
      );
      final container = await ready(tester);
      await ask(tester, 'go');
      await until(tester, () => find.byType(CodeBlock).evaluate().isNotEmpty);
      final card = tester.getSize(find.byType(CodeBlock));
      await until(tester, () => container.read(chatProvider).turns.length == 2);
      // No RenderFlex overflow is the assertion — flutter_test fails on
      // one — and the fence kept its height as the answer finished.
      expect(tester.getSize(find.byType(CodeBlock)).height, card.height);
      expect(find.text('Done.'), findsOneWidget);
    });

    group('waiting (#99)', () {
      /// A fake slow enough that the wait is a state of its own.
      FakeLlmProvider slow({String Function(LlmRequest)? reasoning}) =>
          FakeLlmProvider(
            script: (_) => 'ready.',
            reasoning: reasoning,
            delta: const Duration(milliseconds: 600),
          );

      Future<void> waiting(WidgetTester tester) =>
          until(tester, () => find.byKey(chatWaitingKey).evaluate().isNotEmpty);

      /// Lets the fake finish, so no timer outlives the test.
      Future<void> drain(WidgetTester tester, ProviderContainer c) async {
        await until(tester, () => c.read(chatProvider).turns.length >= 2);
        await tester.pump(const Duration(seconds: 2));
      }

      WaitingDotsPainter painter(WidgetTester tester) =>
          tester
                  .widget<CustomPaint>(
                    find.descendant(
                      of: find.byKey(chatWaitingKey),
                      matching: find.byType(CustomPaint),
                    ),
                  )
                  .painter
              as WaitingDotsPainter;

      testWidgets('the dots breathe while the answer is awaited', (
        tester,
      ) async {
        fake = slow();
        final container = await ready(tester, reduceMotion: false);
        final semantics = tester.ensureSemantics();
        await ask(tester, 'go');
        await waiting(tester);
        expect(
          tester.getSemantics(find.byKey(chatWaitingKey)).label,
          'Waiting for sai',
        );
        expect(find.text('Thinking'), findsNothing);
        final first = painter(tester).alphaOf(0);
        await tester.pump(const Duration(milliseconds: 200));
        expect(painter(tester).alphaOf(0), isNot(closeTo(first, 0.01)));
        expect(
          tester.getSemantics(find.byKey(chatWaitingKey)).label,
          'Waiting for sai',
        );
        // The first delta replaces the dots with the answer.
        await until(tester, () => find.text('ready.').evaluate().isNotEmpty);
        expect(find.byKey(chatWaitingKey), findsNothing);
        await drain(tester, container);
        semantics.dispose();
      });

      testWidgets('Reduce Motion holds a steady Thinking state', (
        tester,
      ) async {
        fake = slow();
        final container = await ready(tester);
        await ask(tester, 'go');
        await waiting(tester);
        expect(find.text('Thinking'), findsOneWidget);
        // No controller, no ticker: the dots are painted once, at rest.
        expect(
          find.descendant(
            of: find.byKey(chatWaitingKey),
            matching: find.byType(AnimatedBuilder),
          ),
          findsNothing,
        );
        expect(painter(tester).phase, isNull);
        final first = painter(tester).alphaOf(0);
        await tester.pump(const Duration(milliseconds: 200));
        expect(painter(tester).alphaOf(0), first);
        expect(painter(tester).alphaOf(2), first);
        await drain(tester, container);
      });

      testWidgets('reasoning names the state as thinking', (tester) async {
        fake = slow(reasoning: (_) => 'hmm');
        final container = await ready(tester);
        final semantics = tester.ensureSemantics();
        await chord(tester, LogicalKeyboardKey.keyR);
        await ask(tester, 'go');
        await waiting(tester);
        expect(
          tester.getSemantics(find.byKey(chatWaitingKey)).label,
          'Waiting for sai',
        );
        await until(tester, () => find.text('hmm').evaluate().isNotEmpty);
        expect(find.byKey(chatWaitingKey), findsOneWidget);
        expect(
          tester.getSemantics(find.byKey(chatWaitingKey)).label,
          'sai is thinking',
        );
        await drain(tester, container);
        semantics.dispose();
      }, variant: macOS);
    });

    group('selection (#99)', () {
      late List<MethodCall> calls;

      setUp(() {
        calls = [];
        TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              calls.add(call);
              return null;
            });
      });

      tearDown(
        () => TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      /// What ⌘C put on the clipboard, or null when nothing was copied.
      String? copied() {
        final copy = calls.where((c) => c.method == 'Clipboard.setData');
        return copy.isEmpty
            ? null
            : (copy.last.arguments as Map)['text'] as String;
      }

      /// A mouse drag from [from] to [to], the way a person selects.
      Future<void> selectByMouse(
        WidgetTester tester,
        Offset from,
        Offset to,
      ) async {
        final gesture = await tester.startGesture(
          from,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await gesture.moveTo(from + const Offset(2, 0));
        await tester.pump();
        await gesture.moveTo(to);
        await tester.pump();
        await gesture.up();
        await tester.pump();
      }

      testWidgets('the transcript is a selection area on the band theme', (
        tester,
      ) async {
        final container = await ready(tester);
        await ask(tester, 'hello');
        await until(
          tester,
          () => container.read(chatProvider).turns.length == 2,
        );
        expect(
          find.ancestor(
            of: find.byKey(chatTranscriptKey),
            matching: find.byType(SelectionArea),
          ),
          findsOneWidget,
        );
        final selection = tester.widget<TextSelectionTheme>(
          find
              .ancestor(
                of: find.byKey(chatFieldKey),
                matching: find.byType(TextSelectionTheme),
              )
              .first,
        );
        expect(selection.data.cursorColor, SaiColors.sheetText);
        expect(selection.data.selectionColor?.a, closeTo(0.28, 0.01));
        expect(
          find.ancestor(
            of: find.byKey(chatTranscriptKey),
            matching: find.byType(TextSelectionTheme),
          ),
          findsWidgets,
        );
      });

      testWidgets('a mouse drag and ⌘C copy a person\'s turn exactly', (
        tester,
      ) async {
        final container = await ready(tester);
        await ask(tester, 'what is due?');
        await until(
          tester,
          () => container.read(chatProvider).turns.length == 2,
        );
        await tester.ensureVisible(
          find.text('what is due?', skipOffstage: false),
        );
        await tester.pump();
        final line = find.text('what is due?');
        await selectByMouse(
          tester,
          tester.getTopLeft(line) - const Offset(4, 0),
          tester.getBottomRight(line) + const Offset(4, 0),
        );
        await chord(tester, LogicalKeyboardKey.keyC);
        expect(copied(), 'what is due?');
      }, variant: macOS);

      testWidgets('a selection across rendered Markdown copies its text', (
        tester,
      ) async {
        fake = FakeLlmProvider(script: (_) => '**bold** and `code` here');
        final container = await ready(tester);
        await ask(tester, 'go');
        await until(
          tester,
          () => container.read(chatProvider).turns.length == 2,
        );
        final line = find.text('bold and code here');
        expect(line, findsOneWidget, reason: screen());
        await selectByMouse(
          tester,
          tester.getTopLeft(line) - const Offset(4, 0),
          tester.getBottomRight(line) + const Offset(4, 0),
        );
        await chord(tester, LogicalKeyboardKey.keyC);
        expect(copied(), 'bold and code here');
      }, variant: macOS);

      testWidgets('a sweep across turns copies them as they read', (
        tester,
      ) async {
        fake = FakeLlmProvider(script: (_) => 'first line\n\n- one\n- two');
        final container = await ready(tester);
        await ask(tester, 'hello');
        await until(
          tester,
          () => container.read(chatProvider).turns.length == 2,
        );
        final from = find.text('hello');
        final to = find.text('two');
        expect(to, findsOneWidget, reason: screen());
        await selectByMouse(
          tester,
          tester.getTopLeft(from) - const Offset(4, 0),
          tester.getBottomRight(to) + const Offset(4, 0),
        );
        await chord(tester, LogicalKeyboardKey.keyC);
        expect(copied(), 'hello\n\nsai\nfirst line\n\n• one\n• two');
      }, variant: macOS);

      testWidgets('a fence copies its code; its label and button stay out', (
        tester,
      ) async {
        fake = FakeLlmProvider(script: (_) => '```dart\nvoid main() {}\n```');
        final container = await ready(tester);
        await ask(tester, 'go');
        await until(
          tester,
          () => container.read(chatProvider).turns.length == 2,
        );
        final code = find.text('void main() {}');
        expect(code, findsOneWidget, reason: screen());
        final transcript = find.byKey(chatTranscriptKey);
        await selectByMouse(
          tester,
          tester.getTopLeft(transcript) + const Offset(2, 2),
          tester.getBottomRight(code) + const Offset(4, 0),
        );
        await chord(tester, LogicalKeyboardKey.keyC);
        final text = copied();
        expect(text, contains('void main() {}'));
        expect(text, isNot(contains('DART')));
        expect(text, isNot(contains('⧉')));
        // The copy control still hands over the fence alone.
        await tester.tap(find.text('⧉'));
        await tester.pump();
        expect(copied(), 'void main() {}');
      }, variant: macOS);

      testWidgets('a touch drag still scrolls the transcript', (tester) async {
        fake = FakeLlmProvider(
          script: (_) => List.generate(60, (i) => 'line $i').join('\n\n'),
        );
        final container = await ready(tester);
        await ask(tester, 'go');
        await until(
          tester,
          () => container.read(chatProvider).turns.length == 2,
        );
        final before = tester.getTopLeft(find.text('line 59')).dy;
        await tester.drag(find.byKey(chatTranscriptKey), const Offset(0, 200));
        await tester.pump();
        expect(tester.getTopLeft(find.text('line 59')).dy, greaterThan(before));
        expect(copied(), isNull);
      });
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
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
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
