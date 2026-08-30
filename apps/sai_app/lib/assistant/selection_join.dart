/// Selection across widgets, joined the way the text reads (#99).
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'markdown/caret.dart';

/// Flutter's selection system copies the selected pieces of adjacent
/// widgets back to back — a turn's eyebrow and its body, or two
/// paragraphs, would land on the clipboard as one run of characters.
/// This container joins what its children selected with [separator], so
/// a copy reads as the transcript does: a line break after an eyebrow,
/// a blank line between paragraphs and between turns. A scroll view is
/// one selectable to its parent and joins its own children back to
/// back, so the join goes inside the list, around its rows.
class SelectionJoin extends StatefulWidget {
  const SelectionJoin({
    super.key,
    required this.separator,
    required this.child,
  });

  final String separator;
  final Widget child;

  @override
  State<SelectionJoin> createState() => _SelectionJoinState();
}

class _SelectionJoinState extends State<SelectionJoin> {
  late final _delegate = _JoiningDelegate(widget.separator);

  @override
  void dispose() {
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SelectionContainer(delegate: _delegate, child: widget.child);
}

class _JoiningDelegate extends StaticSelectionContainerDelegate {
  _JoiningDelegate(this.separator);

  final String separator;

  @override
  SelectedContent? getSelectedContent() {
    final parts = [
      for (final selectable in selectables)
        // A selectable at the selection's edge reports an empty piece;
        // it earns no separator.
        if (selectable.getSelectedContent() case final content?)
          // The streaming cursor is drawn as a span, so a copy taken
          // mid-answer would carry it; it is not text.
          if (content.plainText.replaceAll(caretGlyph, '') case final text
              when text.isNotEmpty)
            text,
    ];
    if (parts.isEmpty) return null;
    return SelectedContent(plainText: parts.join(separator));
  }
}
