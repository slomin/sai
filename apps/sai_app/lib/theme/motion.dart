import 'package:flutter/widgets.dart';

/// The motion policy every animated surface reads: with Reduce Motion on,
/// non-essential animation resolves to [Duration.zero] and settles in one
/// frame. Placed once by the app from `reduceMotionProvider`; later
/// surfaces (the inspector, Settings) read the same policy.
class SaiMotion extends InheritedWidget {
  const SaiMotion({super.key, required this.reduce, required super.child});

  /// Whether the person asked for less motion (macOS Reduce Motion, or
  /// the platform's `disableAnimations` flag).
  final bool reduce;

  /// [duration] as it should run: unchanged, or zero under Reduce Motion.
  Duration of(Duration duration) => reduce ? Duration.zero : duration;

  static SaiMotion of_(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SaiMotion>() ??
      const SaiMotion(reduce: false, child: SizedBox.shrink());

  /// Resolves [duration] for [context]; the policy defaults to full motion
  /// where none is placed (a widget test of a lone primitive).
  static Duration resolve(BuildContext context, Duration duration) =>
      of_(context).of(duration);

  /// Whether motion is reduced for [context].
  static bool reduced(BuildContext context) => of_(context).reduce;

  @override
  bool updateShouldNotify(SaiMotion oldWidget) => reduce != oldWidget.reduce;
}
