/// The assistant's answers, rendered as Markdown with Sai widgets
/// (#39): `package:markdown` parses CommonMark, and everything on
/// screen is drawn by this package's own blocks and spans — no HTML,
/// no third-party widget tree.
library;

import 'package:flutter/widgets.dart';
import 'package:markdown/markdown.dart' as md;

import '../selection_join.dart';
import 'markdown_blocks.dart';
import 'markdown_inline.dart';

/// The streaming cursor (#99): a hair space, then a one-eighth block —
/// a thin bar that stands clear of the last glyph instead of crowding
/// it. It is drawn as a span in the mono face (which has the glyph, so
/// no fallback font can change the line's height), never a widget, so
/// the test finders keep matching plain text (ADR 0018).
const caretGlyph = '\u200a▏';

class SaiMarkdown extends StatefulWidget {
  const SaiMarkdown(
    this.source, {
    super.key,
    required this.style,
    this.caret = false,
  });

  /// The Markdown exactly as the model wrote it. The streaming cursor
  /// is drawn by the renderer, never appended here: a fence line with
  /// the cursor after it would parse as a fence whose language is the
  /// cursor.
  final String source;

  /// The base body style every block derives from.
  final TextStyle style;

  /// Whether the streaming cursor follows the last block.
  final bool caret;

  @override
  State<SaiMarkdown> createState() => _SaiMarkdownState();
}

class _SaiMarkdownState extends State<SaiMarkdown> {
  // A fresh Document per parse — it accumulates link references — and
  // encodeHtml off: we render widgets, not HTML, so `<` must arrive
  // as itself. The parse lives in State: a finished turn's text never
  // changes, so it parses once however often the transcript rebuilds.
  static List<md.Node> _parse(String source) =>
      md.Document(encodeHtml: false).parse(source);

  late List<md.Node> _nodes = _parse(widget.source);

  @override
  void didUpdateWidget(SaiMarkdown old) {
    super.didUpdateWidget(old);
    if (widget.source != old.source) _nodes = _parse(widget.source);
  }

  @override
  Widget build(BuildContext context) {
    // Blocks copy as paragraphs: a blank line between them (#99).
    return SelectionJoin(
      separator: '\n\n',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: markdownBlocks(
          _nodes,
          MarkdownStyles(widget.style),
          caret: widget.caret,
        ),
      ),
    );
  }
}
