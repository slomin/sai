import 'package:flutter/material.dart';

import '../theme/sai_theme.dart';

/// The last notice (a failure, or what just happened), one line, mono.
/// Announced to assistive tech as it changes.
class NoticeLine extends StatelessWidget {
  const NoticeLine(this.text, {super.key, this.textAlign = TextAlign.end});

  final String text;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Text(
        text,
        style: context.saiText.meta,
        textAlign: textAlign,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
