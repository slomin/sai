/// Block Markdown as widgets in the Sai visual system (#39).
library;

import 'package:flutter/widgets.dart';
import 'package:markdown/markdown.dart' as md;

import 'markdown_inline.dart';

const _headings = {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};
const _blockTags = {'p', 'ul', 'ol', 'pre', 'blockquote', 'hr', ..._headings};

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
  for (var i = 0; i < nodes.length; i++) {
    final node = nodes[i];
    final widget = _block(node, styles, caret: caret && i == nodes.length - 1);
    if (widget == null) continue; // A rule, ignored by decision.
    final tag = node is md.Element ? node.tag : 'p';
    if (blocks.isNotEmpty) {
      blocks.add(SizedBox(height: _gap(previous, tag)));
    }
    blocks.add(widget);
    previous = tag;
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
    'blockquote' => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: markdownBlocks(children, styles, caret: caret),
    ),
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
    children: [
      ...markdownSpans(inline, styles),
      if (caret) const TextSpan(text: '▌'),
    ],
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
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) const SizedBox(height: 4),
        Row(
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
      ],
    ],
  );
}

Widget _listItem(md.Element li, MarkdownStyles styles, {required bool caret}) {
  final children = li.children ?? const <md.Node>[];
  final loose = children.any(
    (child) => child is md.Element && _blockTags.contains(child.tag),
  );
  if (!loose) return _paragraph(children, styles, styles.body, caret: caret);
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: markdownBlocks(children, styles, caret: caret),
  );
}

/// A fenced or indented code block. For now a plain mono paragraph;
/// the labelled, highlighted block is the next increment of #39.
Widget _pre(md.Element element, MarkdownStyles styles, {required bool caret}) {
  final code = element.textContent;
  final trimmed = code.endsWith('\n')
      ? code.substring(0, code.length - 1)
      : code;
  return Text.rich(
    TextSpan(
      children: [
        TextSpan(text: trimmed),
        if (caret) const TextSpan(text: '▌'),
      ],
    ),
    style: styles.body.merge(styles.code),
  );
}
