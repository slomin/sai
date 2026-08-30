import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/sai_tokens.dart';
import 'glyph_button.dart';

/// A small cog button — the [GlyphFrame] around a drawn cog, because
/// neither bundled face has U+2699 and an icon font is blank under
/// `flutter test`. [label] is what assistive tech hears and the tooltip.
class CogButton extends StatelessWidget {
  const CogButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.color,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final iconColor = color ?? IconTheme.of(context).color ?? SaiColors.inkDim;
    return GlyphFrame(
      label: label,
      onPressed: onPressed,
      child: CustomPaint(
        size: const Size.square(16),
        painter: _CogPainter(iconColor),
      ),
    );
  }
}

/// Eight teeth around a ring with a hole: one even-odd path, filled.
class _CogPainter extends CustomPainter {
  const _CogPainter(this.color);

  final Color color;

  static const _teeth = 8;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final outer = size.shortestSide / 2;
    final inner = outer * 0.72;
    final hole = outer * 0.3;
    final path = Path()..fillType = PathFillType.evenOdd;
    // Each tooth is a quarter of its pitch wide at the tip, the gap the
    // same at the root, with a step between.
    final pitch = 2 * math.pi / _teeth;
    for (var i = 0; i < _teeth; i++) {
      final start = i * pitch;
      final points = [
        (start, inner),
        (start + pitch * 0.15, outer),
        (start + pitch * 0.35, outer),
        (start + pitch * 0.5, inner),
      ];
      for (final (angle, radius) in points) {
        final p = centre + Offset(math.cos(angle), math.sin(angle)) * radius;
        if (i == 0 && angle == start) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
    }
    path.close();
    path.addOval(Rect.fromCircle(center: centre, radius: hole));
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_CogPainter old) => old.color != color;
}
