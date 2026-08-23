import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:sai_core/sai_core.dart';

/// The terminal shell. Empty on purpose: #41 puts the Today list and chat in.
///
/// Expects a [RiverpodScope] above it; the entry point in `bin/` provides one
/// together with [onQuit], which must end the process (nocterm's
/// `shutdownApp` calls `exit`, so nothing after `runApp` ever runs — any
/// teardown belongs in [onQuit], before that call).
class TuiApp extends StatelessComponent {
  const TuiApp({super.key, required this.onQuit});

  final void Function() onQuit;

  bool _onKey(KeyboardEvent event) {
    final quit =
        event.logicalKey == LogicalKey.keyQ && !event.isAltPressed ||
        event.logicalKey == LogicalKey.keyC && event.isControlPressed;
    if (quit) {
      onQuit();
      return true;
    }
    return false;
  }

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: _onKey,
      child: Container(
        decoration: BoxDecoration(border: BoxBorder.all(color: Colors.gray)),
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: RiverpodConsumer(
                  provider: shellGreetingProvider,
                  builder: (context, greeting) => Text(greeting),
                ),
              ),
            ),
            Text('q quit', style: TextStyle(color: Colors.gray)),
          ],
        ),
      ),
    );
  }
}
