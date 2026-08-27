/// The assistant's Markdown renderer (#39): CommonMark parsed by
/// `package:markdown`, drawn entirely with Sai widgets. These tests
/// pump [SaiMarkdown] directly — no app, no archive.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/assistant/markdown/sai_markdown.dart';
import 'package:sai_app/theme/sai_theme.dart';
import 'package:sai_app/theme/sai_tokens.dart';

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
    expect(find.text('second▌'), findsOneWidget);
    final streaming = tester.getSize(find.byType(SaiMarkdown));
    await pumpMarkdown(tester, 'first\n\nsecond', caret: false);
    expect(find.text('second'), findsOneWidget);
    expect(find.textContaining('▌'), findsNothing);
    expect(tester.getSize(find.byType(SaiMarkdown)).height, streaming.height);
  });

  testWidgets('the caret rides a list from inside its last item', (
    tester,
  ) async {
    await pumpMarkdown(tester, '- alpha\n- beta', caret: true);
    expect(find.text('beta▌'), findsOneWidget);
  });
}
