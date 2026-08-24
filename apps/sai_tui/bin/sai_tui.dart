import 'dart:convert';
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
///
/// Read asynchronously on purpose: a blocking `readLineSync` would keep
/// the SIGINT handler below from ever running, and a `finally` does not
/// run on the default signal exit — either way Ctrl-C at the prompt
/// would leave the shell with echo off.
Future<String?> _readSecret(String prompt) async {
  if (!stdin.hasTerminal) return (await _line())?.trim();
  stdout.write(prompt);
  final echo = stdin.echoMode;
  stdin.echoMode = false;
  final interrupt = ProcessSignal.sigint.watch().listen((_) {
    stdin.echoMode = echo;
    stdout.writeln();
    exit(130);
  });
  try {
    return (await _line())?.trim();
  } finally {
    await interrupt.cancel();
    stdin.echoMode = echo;
    stdout.writeln();
  }
}

/// The first line of stdin, or null when it ends without one.
Future<String?> _line() => stdin
    .transform(utf8.decoder)
    .transform(const LineSplitter())
    .cast<String?>()
    .firstWhere((_) => true, orElse: () => null);
