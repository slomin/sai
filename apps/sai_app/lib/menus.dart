import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'commands.dart';

/// The chrome around the shell: the key bindings (and, with #37's menu
/// bar, the native menus) that drive [AppCommands]. Sits above the
/// shell so its rebuilds are only ever about undo availability and chat
/// visibility, never about what the shell is drawing.
///
/// Cmd+Z is app undo, not text undo, while there is something to undo —
/// #19's tradeoff, kept. With an empty undo stack the chord is not bound
/// at all, so it falls through to the focused text field.
class SaiChrome extends ConsumerWidget {
  const SaiChrome({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final commands = AppCommands.of(context);
    final canUndo = ref.watch(canUndoProvider);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        if (canUndo)
          const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
              commands.undo,
      },
      child: child,
    );
  }
}
