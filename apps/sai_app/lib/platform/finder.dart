import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The Runner's Finder channel (#40): reveal a path in the Finder, or
/// put up an open panel for one file. A thin adapter — the Swift side
/// owns the panels; this side owns nothing but the call. Spawning
/// `open -R` is not an option: no app code starts a process.
const finderChannel = MethodChannel('sai/finder');

/// The one adapter; tests override it with a recording fake.
final finderProvider = Provider<FinderPanel>((ref) => const FinderPanel());

class FinderPanel {
  const FinderPanel();

  /// Shows [path] selected in a Finder window. False when no Runner is
  /// behind the channel (tests, other hosts): the Swift side answers
  /// true, an absent one answers nothing or refuses.
  Future<bool> reveal(String path) async {
    try {
      return await finderChannel.invokeMethod<bool>('reveal', path) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Asks for one file and returns its path, or null when the panel was
  /// cancelled or there is no Runner to show one.
  Future<String?> chooseFile({required String prompt}) async {
    try {
      return await finderChannel.invokeMethod<String>('chooseFile', {
        'prompt': prompt,
      });
    } on MissingPluginException {
      return null;
    }
  }
}
