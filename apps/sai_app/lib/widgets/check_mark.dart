import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/sai_tokens.dart';

/// The square check at the head of a task row. A cancelled task shows a
/// cross instead of a tick; both fill with ink.
class CheckMark extends StatelessWidget {
  const CheckMark({
    super.key,
    required this.checked,
    this.cancelled = false,
    this.onTap,
    this.semanticLabel,
  });

  final bool checked;
  final bool cancelled;
  final VoidCallback? onTap;
  final String? semanticLabel;

  static const size = 18.0;

  @override
  Widget build(BuildContext context) {
    final filled = checked || cancelled;
    final box = AnimatedContainer(
      duration: SaiMotion.resolve(context, SaiDurations.mark),
      curve: Curves.easeOut,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: filled ? SaiColors.ink : SaiColors.white,
        border: Border.all(
          color: filled ? SaiColors.ink : SaiColors.ruleMid,
          width: 1.5,
        ),
        borderRadius: const BorderRadius.all(Radius.circular(4)),
      ),
      child: filled
          ? Icon(
              cancelled ? Icons.close : Icons.check,
              size: 13,
              color: SaiColors.onInk,
            )
          : null,
    );
    return Semantics(
      label: semanticLabel,
      checked: checked,
      button: onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(6), child: box),
      ),
    );
  }
}
