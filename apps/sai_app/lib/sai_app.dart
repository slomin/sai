import 'package:flutter/material.dart';

import 'capture_screen.dart';

/// The macOS shell. Still minimal on purpose — #37 lays out the real
/// one; until then the quick-capture screen (#19) is the whole app.
class SaiApp extends StatelessWidget {
  const SaiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sai',
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      home: const CaptureScreen(),
    );
  }
}
