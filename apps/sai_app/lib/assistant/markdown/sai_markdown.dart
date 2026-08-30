/// The assistant's answers, rendered as Markdown with Sai widgets
/// (#39): `package:markdown` parses CommonMark, and everything on
/// screen is drawn by this package's own blocks and spans — no HTML,
/// no third-party widget tree.
library;

import 'package:flutter/widgets.dart';
import 'package:markdown/markdown.dart' as md;

import 'markdown_blocks.dart';

export 'caret.dart';
import 'markdown_inline.dart';

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
    return markdownColumn(
      _nodes,
      MarkdownStyles(widget.style),
      caret: widget.caret,
    );
  }
}
