import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sai_app/theme/sai_tokens.dart';

/// Loads the bundled families before any test, so text lays out with the
/// real glyphs and the goldens under `test/goldens/` are deterministic.
/// (`flutter test` otherwise draws every family with its block "Ahem"
/// font.) Paths are relative to the package: `flutter test` runs there.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await _load('SpaceGrotesk', ['fonts/SpaceGrotesk[wght].ttf']);
  await _load('JetBrainsMono', [
    'fonts/JetBrainsMono-Regular.ttf',
    'fonts/JetBrainsMono-Medium.ttf',
    'fonts/JetBrainsMono-Bold.ttf',
  ]);
  // The system face (#99, ADR 0020) is Apple's and never bundled: the
  // tests read it from the OS, under the family the theme names, so
  // functional text in a golden is the real thing. macOS only — CI's
  // app job runs there.
  if (Platform.isMacOS) {
    await _load(SaiFonts.sans, ['/System/Library/Fonts/SFNS.ttf']);
  }
  await testMain();
}

Future<void> _load(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final file in files) {
    final bytes = File(file).readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}
