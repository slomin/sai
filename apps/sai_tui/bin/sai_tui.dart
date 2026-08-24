import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:sai_tui/tui_app.dart';

Future<void> main() async {
  final container = ProviderContainer(
    overrides: [eventSourceProvider.overrideWithValue(EventSources.tui)],
  );
  await runApp(
    RiverpodScope(
      container: container,
      child: TuiApp(
        onQuit: () {
          // shutdownApp() ends the process; dispose providers first.
          container.dispose();
          shutdownApp();
        },
      ),
    ),
  );
}
