import 'package:flutter/material.dart';

import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';

/// How a chip reads: `due` is the one red on a screen, `tonal` sits on
/// the surface, `flat` is outlined — status words, not colours.
enum ChipTone { due, tonal, flat }

/// A row's meta as the reference draws it: uppercase mono in a small box.
class SaiChip extends StatelessWidget {
  const SaiChip(this.text, {super.key, this.tone = ChipTone.flat});

  final String text;
  final ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final style = context.saiText.chip;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: switch (tone) {
          ChipTone.due => SaiColors.red,
          ChipTone.tonal => SaiColors.surf,
          ChipTone.flat => null,
        },
        border: tone == ChipTone.flat
            ? Border.all(color: SaiColors.ruleMid)
            : null,
        borderRadius: const BorderRadius.all(Radius.circular(SaiRadius.small)),
      ),
      child: Text(
        text.toUpperCase(),
        style: tone == ChipTone.due
            ? style.copyWith(color: SaiColors.white)
            : style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
