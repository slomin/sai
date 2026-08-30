import 'package:flutter/material.dart';

import '../theme/sai_tokens.dart';

/// The key of the drag handle on [id]'s row, for tests.
Key dragHandleKey(Object id) => ValueKey(('drag', id));

/// The grip a reorderable row carries (#98): six dots, drawn rather than
/// set in a face — deterministic in tests, where no icon font is loaded
/// — a grab cursor, and a label so assistive tech knows what it is for
/// and what the keyboard does instead. It is the one thing on a row that
/// starts a drag: the check completes, nothing else.
class DragHandle extends StatelessWidget {
  const DragHandle({super.key, required this.title, this.color});

  final String title;
  final Color? color;

  static const size = Size(12, 20);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Drag $title',
      hint:
          'Reorders by dragging; Move up and Move down in the menu do the '
          'same',
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: CustomPaint(
          size: size,
          painter: _GripPainter(color ?? SaiColors.inkFaint),
        ),
      ),
    );
  }
}

class _GripPainter extends CustomPainter {
  const _GripPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const r = 1.4;
    final xs = [size.width / 2 - 2.5, size.width / 2 + 2.5];
    final ys = [size.height / 2 - 6, size.height / 2, size.height / 2 + 6];
    for (final x in xs) {
      for (final y in ys) {
        canvas.drawCircle(Offset(x, y), r, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_GripPainter old) => old.color != color;
}
