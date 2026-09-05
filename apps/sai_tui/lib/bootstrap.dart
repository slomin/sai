import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'cli.dart';
import 'tui_app.dart';

/// The terminal client's whole life, shared by the stable and dev entry
/// points (`bin/sai_tui.dart`, `bin/sai_tui-dev.dart`). They differ in
/// nothing but [identity], which decides the archive, settings and
/// Keychain service this process reads (ADR 0019).
///
/// With [args] this is a command, not the client: settings and keys from
/// the shell. Without, the interactive app.
Future<void> runSaiTui(
  List<String> args, {
  required SaiIdentity identity,
}) async {
  final container = ProviderContainer(
    overrides: [
      identityProvider.overrideWithValue(identity),
      eventSourceProvider.overrideWithValue(EventSources.tui),
    ],
  );
  if (args.isNotEmpty) {
    try {
      exitCode = await runCli(
        args,
        container: container,
        out: stdout,
        err: stderr,
        readSecret: _readSecret,
        readLine: _readLine,
      );
    } finally {
      // On every path out, an exception's included: the archive's LOCK
      // goes with the container, and a held stdin would keep the process
      // alive.
      await _stdinLines?.cancel();
      _stdinLines = null;
      container.dispose();
    }
    return;
  }
  keepConnectionAlive(container);
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

/// Keeps the connection probe running for the process (#105): nothing
/// the TUI renders watches [connectionProvider], and the chat budget
/// follows the context window that probe reports.
void keepConnectionAlive(ProviderContainer container) {
  container.listen(connectionProvider, (_, _) {});
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

/// One line from the terminal, echoed — a decision is not a secret — or
/// from a piped stdin as it is. The prompt is shown to a terminal only,
/// so piped answers are never interleaved with questions.
Future<String?> _readLine(String prompt) {
  if (stdin.hasTerminal && prompt.isNotEmpty) stdout.write(prompt);
  return _line();
}

/// stdin as lines, opened on the first read and held for the command:
/// stdin is a single-subscription stream, and `decision add` asks more
/// than once. Cancelled when the command ends, or the process would wait
/// on a terminal that has nothing more to say.
StreamIterator<String>? _stdinLines;

/// The next line of stdin, or null when it ends.
Future<String?> _line() async {
  final lines = _stdinLines ??= StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  return await lines.moveNext() ? lines.current : null;
}
