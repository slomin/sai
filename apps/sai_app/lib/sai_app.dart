import 'package:flutter/material.dart';

import 'menus.dart';
import 'shell.dart';

/// The macOS app: the shell (#37) inside its chrome. Appearance follows
/// the system; the palette is Material's default until a design pass.
class SaiApp extends StatelessWidget {
  const SaiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sai',
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: ThemeMode.system,
      home: const SaiChrome(child: SaiShell()),
    );
  }
}
