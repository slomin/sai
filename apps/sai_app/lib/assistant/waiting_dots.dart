/// The waiting indicator (#99): what the band shows between a question
/// going out and the first delta coming back.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';

/// Three dots that breathe in turn — restrained, one cycle of
/// [SaiDurations.pulse]. Under Reduce Motion nothing loops: the dots
/// hold a steady tone beside the word *Thinking*. Assistive technology
/// hears [label] once, and it stays the same however the dots move.
class WaitingDots extends StatefulWidget {
  const WaitingDots({super.key, required this.label});

  /// The stable accessible name of the state, e.g. `Waiting for sai`.
  final String label;

  @override
  State<WaitingDots> createState() => _WaitingDotsState();
}

// A full ticker provider: the controller is dropped and made again as
// Reduce Motion goes on and off, and the single-ticker mixin allows one.
class _WaitingDotsState extends State<WaitingDots>
    with TickerProviderStateMixin {
  AnimationController? _pulse;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (SaiMotion.reduced(context)) {
      _pulse?.dispose();
      _pulse = null;
    } else {
      _pulse ??= AnimationController(vsync: this, duration: SaiDurations.pulse)
        ..repeat();
    }
  }

  @override
  void dispose() {
    _pulse?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pulse = _pulse;
    // The body line's height at the reader's text scale, so the first
    // delta replacing the dots moves nothing.
    final size = Size(
      WaitingDotsPainter.width,
      MediaQuery.textScalerOf(context).scale(WaitingDotsPainter.lineHeight),
    );
    return Semantics(
      container: true,
      liveRegion: true,
      label: widget.label,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pulse == null)
            CustomPaint(size: size, painter: const WaitingDotsPainter())
          else
            AnimatedBuilder(
              animation: pulse,
              builder: (_, _) => CustomPaint(
                size: size,
                painter: WaitingDotsPainter(phase: pulse.value),
              ),
            ),
          if (pulse == null) ...[
            const SizedBox(width: 8),
            // Chrome, like a fence's label: never part of a copy.
            SelectionContainer.disabled(
              child: Text(
                'Thinking',
                style: context.saiText.small.copyWith(
                  color: SaiColors.sheetDim,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The three dots at [phase] of the cycle (0–1); null holds them all
/// at the steady tone.
class WaitingDotsPainter extends CustomPainter {
  const WaitingDotsPainter({this.phase});

  final double? phase;

  /// The row's box at text scale 1: the transcript body's line
  /// (15 × 1.5), scaled by the widget with the reader's text.
  static const width = 30.0;
  static const lineHeight = 22.5;

  static const _dots = 3;
  static const _radius = 2.5;
  static const _step = 9.0;

  /// The tone of dot [i]: steady at rest, breathing with the phase.
  double alphaOf(int i) {
    final phase = this.phase;
    if (phase == null) return 0.7;
    final wave = 0.5 + 0.5 * math.cos(2 * math.pi * (phase - i / _dots));
    return 0.3 + 0.65 * wave;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    for (var i = 0; i < _dots; i++) {
      canvas.drawCircle(
        Offset(_radius + i * _step, y),
        _radius,
        Paint()..color = SaiColors.sheetDim.withValues(alpha: alphaOf(i)),
      );
    }
  }

  @override
  bool shouldRepaint(WaitingDotsPainter old) => old.phase != phase;
}
