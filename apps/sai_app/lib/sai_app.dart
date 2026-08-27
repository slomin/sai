import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'menus.dart';
import 'platform/reduce_motion.dart';
import 'setup/first_run.dart';
import 'shell.dart';
import 'theme/motion.dart';
import 'theme/sai_theme.dart';
import 'workspace/workspace_state.dart';

/// The macOS app: the shell (#37) inside its chrome, in the Sai visual
/// system (#72). Light appearance only for now — the reference defines
/// one palette; a dark variant is a later ticket. The motion policy is
/// placed here so every surface below reads the same one.
class SaiApp extends ConsumerWidget {
  const SaiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'sai',
      debugShowCheckedModeBanner: false,
      theme: saiTheme(),
      themeMode: ThemeMode.light,
      builder: (context, child) => SaiMotion(
        reduce:
            ref.watch(reduceMotionProvider) ||
            MediaQuery.disableAnimationsOf(context),
        child: child!,
      ),
      home: const SaiChrome(
        child: WorkspaceRestorer(child: FirstRunGate(child: SaiShell())),
      ),
    );
  }
}
