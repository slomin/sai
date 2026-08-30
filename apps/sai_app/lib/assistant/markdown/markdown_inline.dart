/// Inline Markdown as [InlineSpan]s in the Sai visual system (#39).
library;

import 'package:flutter/painting.dart';
import 'package:markdown/markdown.dart' as md;

import '../../theme/sai_tokens.dart';
import 'sai_markdown.dart';

/// The styles the renderer draws with, derived from the transcript's
/// base body style. The rule that keeps streaming stable: no inline
/// span may grow the line box its paragraph already has — a taller
/// line arriving mid-answer is the layout jump #39 forbids.
class MarkdownStyles {
  MarkdownStyles(this.body);

  /// The paragraph style — the band's body text, whole.
  final TextStyle body;

  /// Headings are stronger paragraphs, never larger ones: same size,
  /// heavier weight, so a `#` cannot reflow the lines under it.
  late final TextStyle heading = body.copyWith(fontWeight: FontWeight.w700);

  /// The inline code chip: mono, one point smaller on the same line
  /// height, so its line box never exceeds the paragraph's.
  late final TextStyle code = TextStyle(
    fontFamily: SaiFonts.mono,
    fontSize: (body.fontSize ?? 14) - 1,
    height: body.height,
    backgroundColor: SaiColors.sheetCard,
  );

  /// The code block's body: the chip's face without its background —
  /// the card is the surface there.
  late final TextStyle codeBlock = body.copyWith(
    fontFamily: SaiFonts.mono,
    fontSize: (body.fontSize ?? 14) - 1,
  );

  /// The streaming cursor, [caretGlyph] in the accent: the body's line
  /// height, so the bar never grows the line it ends.
  late final TextSpan caret = TextSpan(
    text: caretGlyph,
    style: TextStyle(
      fontFamily: SaiFonts.mono,
      height: body.height,
      color: SaiColors.red,
    ),
  );

  /// Bold and italic, as deltas Flutter merges into the surround.
  static const strong = TextStyle(fontWeight: FontWeight.w700);
  static const em = TextStyle(fontStyle: FontStyle.italic);

  /// A link is named in the accent, not underlined — an underline
  /// promises a click this pane does not offer.
  static const link = TextStyle(color: SaiColors.red);

  /// List markers sit a shade dimmer than their items.
  static const marker = TextStyle(color: SaiColors.sheetDim);
}

/// The spans for [nodes]. Styles nest as deltas, so `**a *b* c**`
/// merges the way text expects.
List<InlineSpan> markdownSpans(List<md.Node> nodes, MarkdownStyles styles) => [
  for (final node in nodes) _span(node, styles),
];

InlineSpan _span(md.Node node, MarkdownStyles styles) {
  // Soft line breaks survive as literal newlines inside the text.
  if (node is! md.Element) return TextSpan(text: node.textContent);
  final children = node.children ?? const <md.Node>[];
  return switch (node.tag) {
    'em' => TextSpan(
      style: MarkdownStyles.em,
      children: markdownSpans(children, styles),
    ),
    'strong' => TextSpan(
      style: MarkdownStyles.strong,
      children: markdownSpans(children, styles),
    ),
    'code' => TextSpan(text: node.textContent, style: styles.code),
    'a' => TextSpan(
      style: MarkdownStyles.link,
      children: markdownSpans(children, styles),
    ),
    'br' => const TextSpan(text: '\n'),
    'img' => TextSpan(text: node.attributes['alt'] ?? ''),
    // Anything unexpected keeps its text; nothing is dropped.
    _ => TextSpan(children: markdownSpans(children, styles)),
  };
}
