/// A fenced code block (#39): a card with a header naming the
/// language and offering copy, over a body that scrolls sideways —
/// so a long line arriving mid-stream can never rewrap what is
/// already on screen, and the block's height is exactly its line
/// count.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/sai_theme.dart';
import '../../theme/sai_tokens.dart';
import '../../widgets/glyph_button.dart';
import 'code_syntax.dart';
import 'markdown_inline.dart';

class CodeBlock extends StatefulWidget {
  const CodeBlock(
    this.code, {
    super.key,
    this.language,
    required this.style,
    this.caret = false,
  });

  /// The fence's body, without its trailing newline.
  final String code;

  /// What the fence was tagged, or null for an untagged one.
  final String? language;

  /// The mono body style; highlighting adds only colour and weight.
  final TextStyle style;

  /// Whether the streaming cursor follows the last line.
  final bool caret;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  // Tokenized once per text, in State — however often the transcript
  // rebuilds, a finished block never re-runs the regex engine.
  late List<TextSpan> _spans = codeSpans(widget.code, widget.language);
  Timer? _copied;

  @override
  void didUpdateWidget(CodeBlock old) {
    super.didUpdateWidget(old);
    if (widget.code != old.code || widget.language != old.language) {
      _spans = codeSpans(widget.code, widget.language);
    }
  }

  @override
  void dispose() {
    _copied?.cancel();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.code));
    _copied?.cancel();
    setState(() {
      _copied = Timer(SaiDurations.hold, () {
        if (mounted) setState(() => _copied = null);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final copied = _copied != null;
    return Container(
      decoration: const BoxDecoration(
        color: SaiColors.sheetCard,
        border: Border.fromBorderSide(BorderSide(color: SaiColors.sheetRule)),
        borderRadius: BorderRadius.all(Radius.circular(SaiRadius.medium)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The label and the copy control are chrome: a selection
          // sweeping the transcript (#99) takes the code, never them.
          SelectionContainer.disabled(
            child: Container(
              height: 28,
              padding: const EdgeInsets.only(left: 10, right: 4),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: SaiColors.sheetRule)),
              ),
              child: Row(
                children: [
                  // Flexible: the fence's tag is the model's to write,
                  // and an absurd one must ellipsise, not overflow.
                  Flexible(
                    child: Text(
                      (widget.language ?? 'text').toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.saiText.chip.copyWith(
                        color: SaiColors.sheetDim,
                      ),
                    ),
                  ),
                  const Spacer(),
                  GlyphButton(
                    glyph: copied ? '✓' : '⧉',
                    label: copied ? 'Copied' : 'Copy the code',
                    onPressed: _copy,
                    color: SaiColors.sheetDim,
                    size: 12,
                    minSize: 24,
                  ),
                ],
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Text.rich(
              TextSpan(
                children: [
                  ..._spans,
                  if (widget.caret) MarkdownStyles(widget.style).caret,
                ],
              ),
              style: widget.style,
              softWrap: false,
            ),
          ),
        ],
      ),
    );
  }
}
