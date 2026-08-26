import 'package:flutter/material.dart';

import '../theme/sai_theme.dart';

/// The small uppercase mono label that opens a section or a group — the
/// reference's "uppercase eyebrow". Red for the headline, dim for groups
/// and meta.
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key, this.dim = false});

  final String text;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final text_ = context.saiText;
    return Text(
      text.toUpperCase(),
      style: dim ? text_.eyebrowDim : text_.eyebrow,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
