/// The assistant's Markdown renderer (#39): CommonMark parsed by
/// `package:markdown`, drawn entirely with Sai widgets. These tests
/// pump [SaiMarkdown] directly — no app, no archive.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/assistant/markdown/code_block.dart';
import 'package:sai_app/assistant/markdown/sai_markdown.dart';
import 'package:sai_app/theme/sai_theme.dart';
import 'package:sai_app/theme/sai_tokens.dart';
import 'package:sai_app/widgets/glyph_button.dart';

/// The transcript's body style, as the band passes it in.
final _body = sans(15, height: 1.5, color: SaiColors.sheetText);

Future<void> pumpMarkdown(
  WidgetTester tester,
  String source, {
  bool caret = false,
}) => tester.pumpWidget(
  MaterialApp(
    theme: saiTheme(),
    home: Scaffold(
      backgroundColor: SaiColors.sheetBg,
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 640,
          child: SaiMarkdown(source, style: _body, caret: caret),
        ),
      ),
    ),
  ),
);

/// Every leaf span of the rich [Text] whose plain text is [plain],
/// keyed by its text, with the styles of its ancestors merged in.
Map<String, TextStyle> spansOf(WidgetTester tester, String plain) {
  final text = tester.widget<Text>(find.text(plain));
  final merged = <String, TextStyle>{};
  void walk(InlineSpan span, TextStyle? inherited) {
    if (span is! TextSpan) return;
    final style = span.style == null
        ? inherited
        : (inherited?.merge(span.style) ?? span.style);
    if (span.text != null) merged[span.text!] = style ?? const TextStyle();
    for (final child in span.children ?? const <InlineSpan>[]) {
      walk(child, style);
    }
  }

  walk(text.textSpan!, text.style);
  return merged;
}

void main() {
  testWidgets('bold, italic, code and links style their spans', (tester) async {
    await pumpMarkdown(
      tester,
      'a **bold** move with *style*, `code` and [a link](https://x).',
    );
    final spans = spansOf(tester, 'a bold move with style, code and a link.');
    expect(spans['bold']!.fontWeight, FontWeight.w700);
    expect(spans['style']!.fontStyle, FontStyle.italic);
    expect(spans['code']!.fontFamily, SaiFonts.mono);
    expect(spans['code']!.fontSize, 14);
    expect(spans['a link']!.color, SaiColors.red);
    expect(spans['a link']!.decoration, isNot(TextDecoration.underline));
  });

  testWidgets('inline code never grows the line box', (tester) async {
    await pumpMarkdown(tester, 'plain words here');
    final plain = tester.getSize(find.text('plain words here'));
    await pumpMarkdown(tester, 'plain `words` here');
    final chipped = tester.getSize(find.text('plain words here'));
    expect(chipped.height, plain.height);
  });

  testWidgets('bulleted and numbered lists get markers', (tester) async {
    await pumpMarkdown(tester, '- alpha\n- beta\n\n3. gamma\n4. delta');
    expect(find.text('•'), findsNWidgets(2));
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
    // An ordered list keeps the number it starts at.
    expect(find.text('3.'), findsOneWidget);
    expect(find.text('4.'), findsOneWidget);
    expect(find.text('gamma'), findsOneWidget);
  });

  testWidgets('headings are stronger paragraphs, not larger ones', (
    tester,
  ) async {
    await pumpMarkdown(tester, '# Title\n\nbody text');
    final title = tester.widget<Text>(find.text('Title'));
    expect(title.style!.fontSize, _body.fontSize);
    expect(title.style!.fontWeight, FontWeight.w700);
    final body = tester.widget<Text>(find.text('body text'));
    expect(body.style!.fontWeight, isNot(FontWeight.w700));
  });

  testWidgets('blockquotes flatten and rules vanish', (tester) async {
    await pumpMarkdown(tester, '> quoted words\n\nplain words\n\n***');
    expect(find.text('quoted words'), findsOneWidget);
    expect(find.textContaining('*'), findsNothing);
    expect(find.textContaining('>'), findsNothing);
  });

  testWidgets('a soft line break stays one paragraph', (tester) async {
    await pumpMarkdown(tester, 'line one\nline two');
    expect(find.text('line one\nline two'), findsOneWidget);
  });

  testWidgets('the caret rides the last block, and completion removes '
      'nothing else', (tester) async {
    await pumpMarkdown(tester, 'first\n\nsecond', caret: true);
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second$caretGlyph'), findsOneWidget);
    final streaming = tester.getSize(find.byType(SaiMarkdown));
    await pumpMarkdown(tester, 'first\n\nsecond', caret: false);
    expect(find.text('second'), findsOneWidget);
    expect(find.textContaining(caretGlyph), findsNothing);
    expect(tester.getSize(find.byType(SaiMarkdown)).height, streaming.height);
  });

  testWidgets('the caret is a thin red bar set off from the last glyph', (
    tester,
  ) async {
    await pumpMarkdown(tester, 'word', caret: true);
    final spans = spansOf(tester, 'word$caretGlyph');
    final caret = spans[caretGlyph]!;
    expect(caretGlyph, startsWith('\u200a'));
    expect(caret.fontFamily, SaiFonts.mono);
    expect(caret.color, SaiColors.red);
    expect(caret.height, _body.height);
    expect(spans['word']!.fontFamily, _body.fontFamily);
  });

  testWidgets('the caret rides a list from inside its last item', (
    tester,
  ) async {
    await pumpMarkdown(tester, '- alpha\n- beta', caret: true);
    expect(find.text('beta$caretGlyph'), findsOneWidget);
  });

  testWidgets('fenced code gets a card, a label and highlighting', (
    tester,
  ) async {
    await pumpMarkdown(tester, 'Look:\n\n```dart\nvoid main() {}\n```');
    expect(find.byType(CodeBlock), findsOneWidget);
    expect(find.text('DART'), findsOneWidget);
    final spans = spansOf(tester, 'void main() {}');
    expect(spans.values.any((s) => s.color == SaiColors.red), isTrue);
  });

  testWidgets('an untagged fence stays plain mono', (tester) async {
    await pumpMarkdown(tester, '```\nplain code here\n```');
    expect(find.text('TEXT'), findsOneWidget);
    final spans = spansOf(tester, 'plain code here');
    expect(spans.values.every((s) => s.color == SaiColors.sheetText), isTrue);
    expect(spans.values.every((s) => s.fontFamily == SaiFonts.mono), isTrue);
  });

  testWidgets('the copy button hands the fence to the clipboard', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pumpMarkdown(tester, '```dart\nvoid main() {}\n```');
    await tester.tap(find.byType(GlyphButton));
    await tester.pump();
    final copy = calls.singleWhere((c) => c.method == 'Clipboard.setData');
    expect((copy.arguments as Map)['text'], 'void main() {}');
    // The confirmation shows, then drains its own timer.
    expect(find.text('✓'), findsOneWidget);
    await tester.pump(SaiDurations.hold);
    await tester.pump();
    expect(find.text('⧉'), findsOneWidget);
  });

  testWidgets('an unfinished fence is already a code block, and stays put', (
    tester,
  ) async {
    const full = 'Here:\n\n```dart\nvoid main() {\n  print(1);\n}\n```';
    double? width;
    var height = 0.0;
    var seen = false;
    for (var i = 1; i <= full.length; i++) {
      await pumpMarkdown(tester, full.substring(0, i), caret: true);
      final block = find.byType(CodeBlock);
      if (tester.any(block)) {
        seen = true;
        final size = tester.getSize(block);
        width ??= size.width;
        expect(size.width, width, reason: 'width moved at $i');
        expect(
          size.height,
          greaterThanOrEqualTo(height),
          reason: 'height shrank at $i',
        );
        height = size.height;
      } else {
        expect(seen, isFalse, reason: 'the block vanished at $i');
      }
    }
    expect(seen, isTrue);
    expect(find.byType(CodeBlock), findsOneWidget);
  });

  testWidgets('the caret joins the code, never the language label', (
    tester,
  ) async {
    await pumpMarkdown(tester, 'Here:\n\n```\nfoo', caret: true);
    expect(find.text('TEXT'), findsOneWidget);
    expect(find.text('foo$caretGlyph'), findsOneWidget);
  });

  testWidgets('the reference sample matches its golden', (tester) async {
    const sample = '''
# The plan

A **bold** step, an *aside*, some `inline code`, and
[a link](https://example.com) to nowhere.

- first thing
- second thing

1. in order
2. and again

```dart
void main() {
  print('hello');
}
```

```
no language here
```''';
    await pumpMarkdown(tester, sample);
    await expectLater(
      find.byType(SaiMarkdown),
      matchesGoldenFile('goldens/assistant-markdown.png'),
    );
  });

  testWidgets('a streaming turn matches its golden', (tester) async {
    await pumpMarkdown(
      tester,
      '## Half an answer\n\nThe first paragraph is whole, the second is '
      'still arriving with a `span` in it and the cursor after',
      caret: true,
    );
    await expectLater(
      find.byType(SaiMarkdown),
      matchesGoldenFile('goldens/assistant-streaming.png'),
    );
  });

  testWidgets('a tilde fence holds its partial closing line too', (
    tester,
  ) async {
    const open = 'Here:\n\n~~~\ncode line\n';
    await pumpMarkdown(tester, open, caret: true);
    final settled = tester.getSize(find.byType(CodeBlock)).height;
    for (final tail in ['~', '~~', '~~~']) {
      await pumpMarkdown(tester, open + tail, caret: true);
      expect(find.byType(CodeBlock), findsOneWidget);
      expect(
        tester.getSize(find.byType(CodeBlock)).height,
        settled,
        reason: 'height moved at "$tail"',
      );
    }
  });

  testWidgets('the caret survives a stream that ends on a rule', (
    tester,
  ) async {
    await pumpMarkdown(tester, 'text\n\n***', caret: true);
    expect(find.text('text$caretGlyph'), findsOneWidget);
  });

  testWidgets('a whitespace-only stream still shows the caret', (tester) async {
    await pumpMarkdown(tester, '\n', caret: true);
    expect(find.text(caretGlyph), findsOneWidget);
  });

  testWidgets('an absurd fence tag ellipsises instead of overflowing', (
    tester,
  ) async {
    final tag = 'x' * 400;
    await pumpMarkdown(tester, '```$tag\ncode\n```');
    // No RenderFlex overflow is the assertion; the copy control stays.
    expect(find.text('⧉'), findsOneWidget);
  });
}
