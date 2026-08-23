import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/riverpod.dart';
import 'package:sai_tui/tui_app.dart';

Future<void> main() async {
  final container = ProviderContainer();
  try {
    await runApp(RiverpodScope(container: container, child: const TuiApp()));
  } finally {
    container.dispose();
  }
}
