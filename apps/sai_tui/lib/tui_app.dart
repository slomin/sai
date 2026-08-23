import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:sai_core/sai_core.dart';

/// The terminal shell. Empty on purpose: #41 puts the Today list and chat in.
///
/// Expects a [RiverpodScope] above it; the entry point in `bin/` provides one.
class TuiApp extends StatelessComponent {
  const TuiApp({super.key});

  bool _onKey(KeyboardEvent event) {
    final quit =
        event.logicalKey == LogicalKey.keyQ && !event.isAltPressed ||
        event.logicalKey == LogicalKey.keyC && event.isControlPressed;
    if (quit) {
      shutdownApp();
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
