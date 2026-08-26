import 'package:flutter/material.dart';

import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';

/// A small button drawn with a text glyph (`…`, `+`, `✕`) in the bundled
/// mono face rather than an icon font — the reference's typographic
/// idiom, and deterministic in tests where no icon font is loaded.
/// [label] is what assistive tech hears and the tooltip.
class GlyphButton extends StatelessWidget {
  const GlyphButton({
    super.key,
    required this.glyph,
    required this.label,
    required this.onPressed,
    this.color,
    this.size = 14,
    this.minSize = 28,
  });

  final String glyph;
  final String label;
  final VoidCallback? onPressed;
  final Color? color;
  final double size;
  final double minSize;

  @override
  Widget build(BuildContext context) {
    final iconColor = color ?? IconTheme.of(context).color ?? SaiColors.inkDim;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        enabled: onPressed != null,
        child: ExcludeSemantics(
          child: InkWell(
            onTap: onPressed,
            borderRadius: const BorderRadius.all(
              Radius.circular(SaiRadius.small),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: minSize,
                minHeight: minSize,
              ),
              child: Center(
                child: Text(
                  glyph,
                  style: context.saiText.meta.copyWith(
                    fontSize: size,
                    height: 1,
                    letterSpacing: 0,
                    color: iconColor,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
