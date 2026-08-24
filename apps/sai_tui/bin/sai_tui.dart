import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:sai_tui/cli.dart';
import 'package:sai_tui/tui_app.dart';

Future<void> main(List<String> args) async {
  final container = ProviderContainer(
    overrides: [eventSourceProvider.overrideWithValue(EventSources.tui)],
  );
  if (args.isNotEmpty) {
    // A command, not the client: settings and keys from the shell.
    exitCode = await runCli(
      args,
      container: container,
      out: stdout,
      err: stderr,
      readSecret: _readSecret,
    );
    container.dispose();
    return;
  }
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

/// One line from the terminal with echo off, so the key never shows or
/// lands in the scrollback; a piped stdin is read as it is.
String? _readSecret(String prompt) {
  if (!stdin.hasTerminal) return stdin.readLineSync()?.trim();
  stdout.write(prompt);
  final echo = stdin.echoMode;
  stdin.echoMode = false;
  try {
    return stdin.readLineSync()?.trim();
  } finally {
    stdin.echoMode = echo;
    stdout.writeln();
  }
}
