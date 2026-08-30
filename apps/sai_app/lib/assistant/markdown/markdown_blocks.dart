/// Block Markdown as widgets in the Sai visual system (#39).
library;

import 'package:flutter/widgets.dart';
import 'package:markdown/markdown.dart' as md;

import '../selection_join.dart';
import 'code_block.dart';
import 'markdown_inline.dart';

const _headings = {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};

/// A line that is nothing but fence delimiters — the closing fence
/// arriving, whatever its character and length.
final _partialFence = RegExp(r'^(`+|~+)$');
const _blockTags = {'p', 'ul', 'ol', 'pre', 'blockquote', 'hr', ..._headings};

/// The blocks for [nodes] as one column that copies as paragraphs: a
/// blank line between blocks (#99), wherever blocks nest — a turn, a
/// loose list item, a quote.
Widget markdownColumn(
  List<md.Node> nodes,
  MarkdownStyles styles, {
  bool caret = false,
}) => SelectionJoin(
  separator: '\n\n',
  child: Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: markdownBlocks(nodes, styles, caret: caret),
  ),
);

/// The widgets for [nodes]. With [caret] the streaming cursor follows
/// the last block — appended to the rendered spans, never to the
/// source, so the cursor cannot change a parse.
List<Widget> markdownBlocks(
  List<md.Node> nodes,
  MarkdownStyles styles, {
  bool caret = false,
}) {
  final blocks = <Widget>[];
  var previous = '';
  // The caret goes on the last node that draws — a trailing rule is
  // dropped, and the cursor must not vanish with it.
  var caretIndex = -1;
  if (caret) {
    for (var i = nodes.length - 1; i >= 0; i--) {
      final node = nodes[i];
      if (node is! md.Element || node.tag != 'hr') {
        caretIndex = i;
        break;
      }
    }
  }
  for (var i = 0; i < nodes.length; i++) {
    final node = nodes[i];
    final widget = _block(node, styles, caret: i == caretIndex);
    if (widget == null) continue; // A rule, ignored by decision.
    final tag = node is md.Element ? node.tag : 'p';
    if (blocks.isNotEmpty) {
      blocks.add(SizedBox(height: _gap(previous, tag)));
    }
    blocks.add(widget);
    previous = tag;
  }
  // Nothing drew — the stream is whitespace, or rules alone — but the
  // answer is still coming: the cursor stands on its own.
  if (caret && blocks.isEmpty) {
    blocks.add(Text.rich(styles.caret, style: styles.body));
  }
  return blocks;
}

/// Headings breathe: room above, close to what they head below.
double _gap(String previous, String next) {
  if (_headings.contains(next)) return 14;
  if (_headings.contains(previous)) return 4;
  return 10;
}

Widget? _block(md.Node node, MarkdownStyles styles, {required bool caret}) {
  if (node is! md.Element) {
    return _paragraph([node], styles, styles.body, caret: caret);
  }
  final children = node.children ?? const <md.Node>[];
  if (_headings.contains(node.tag)) {
    return _paragraph(children, styles, styles.heading, caret: caret);
  }
  return switch (node.tag) {
    'p' => _paragraph(children, styles, styles.body, caret: caret),
    'ul' => _list(node, styles, ordered: false, caret: caret),
    'ol' => _list(node, styles, ordered: true, caret: caret),
    'pre' => _pre(node, styles, caret: caret),
    // Flattened by decision: the band is already a quoted surface.
    'blockquote' => markdownColumn(children, styles, caret: caret),
    'hr' => null,
    // Anything unexpected keeps its text; nothing is dropped.
    _ => _paragraph(children, styles, styles.body, caret: caret),
  };
}

Widget _paragraph(
  List<md.Node> inline,
  MarkdownStyles styles,
  TextStyle style, {
  required bool caret,
}) => Text.rich(
  TextSpan(
    children: [...markdownSpans(inline, styles), if (caret) styles.caret],
  ),
  style: style,
);

Widget _list(
  md.Element element,
  MarkdownStyles styles, {
  required bool ordered,
  required bool caret,
}) {
  final items = [
    for (final child in element.children ?? const <md.Node>[])
      if (child is md.Element && child.tag == 'li') child,
  ];
  final start = int.tryParse(element.attributes['start'] ?? '') ?? 1;
  // Items copy one per line, each after its marker (#99).
  return SelectionJoin(
    separator: '\n',
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(height: 4),
          SelectionJoin(
            separator: ' ',
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 24,
                  child: Text(
                    ordered ? '${start + i}.' : '•',
                    style: styles.body.merge(MarkdownStyles.marker),
                  ),
                ),
                Expanded(
                  child: _listItem(
                    items[i],
                    styles,
                    caret: caret && i == items.length - 1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    ),
  );
}

Widget _listItem(md.Element li, MarkdownStyles styles, {required bool caret}) {
  final children = li.children ?? const <md.Node>[];
  final loose = children.any(
    (child) => child is md.Element && _blockTags.contains(child.tag),
  );
  if (!loose) return _paragraph(children, styles, styles.body, caret: caret);
  return markdownColumn(children, styles, caret: caret);
}

/// A fenced or indented code block, as the labelled card. The fence's
/// tag arrives as a `language-…` class on the inner `code` element.
Widget _pre(md.Element element, MarkdownStyles styles, {required bool caret}) {
  final children = element.children;
  final child = children == null || children.isEmpty ? null : children.first;
  String? language;
  if (child is md.Element) {
    final tag = child.attributes['class'];
    if (tag != null && tag.startsWith('language-')) {
      language = tag.substring('language-'.length);
    }
  }
  final code = element.textContent;
  var trimmed = code.endsWith('\n') ? code.substring(0, code.length - 1) : code;
  // While the answer still streams, a last line of nothing but
  // backticks or tildes is almost surely the closing fence arriving;
  // drawing it would add a line its completion takes away — a jump.
  // Hold it, whatever the fence character or length.
  if (caret) {
    final cut = trimmed.lastIndexOf('\n');
    final lastLine = trimmed.substring(cut + 1);
    if (_partialFence.hasMatch(lastLine)) {
      trimmed = cut < 0 ? '' : trimmed.substring(0, cut);
    }
  }
  return CodeBlock(
    trimmed,
    language: language,
    style: styles.codeBlock,
    caret: caret,
  );
}
