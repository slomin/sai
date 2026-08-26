import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The Runner's accessibility channel: macOS Reduce Motion, which the
/// embedder does not forward as `disableAnimations` (only iOS does). The
/// Swift side answers `reduceMotion` and calls `reduceMotionChanged`
/// when System Settings flips it.
const reduceMotionChannel = MethodChannel('sai/accessibility');

/// Whether the person asked macOS for less motion. Starts false and
/// follows the channel; tests override it outright.
final reduceMotionProvider = NotifierProvider<ReduceMotion, bool>(
  ReduceMotion.new,
);

class ReduceMotion extends Notifier<bool> {
  @override
  bool build() {
    reduceMotionChannel.setMethodCallHandler(_onCall);
    ref.onDispose(() => reduceMotionChannel.setMethodCallHandler(null));
    unawaited(_read());
    return false;
  }

  Future<void> _read() async {
    bool? value;
    try {
      value = await reduceMotionChannel.invokeMethod<bool>('reduceMotion');
    } on MissingPluginException {
      // No Runner behind the channel (tests, other hosts): keep full motion.
      return;
    }
    if (ref.mounted && value != null) state = value;
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'reduceMotionChanged' && call.arguments is bool) {
      if (ref.mounted) state = call.arguments as bool;
    }
    return null;
  }
}
