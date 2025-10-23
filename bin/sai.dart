import 'dart:io';

import 'package:sai/src/cli.dart';

Future<void> main(List<String> args) async {
  final exitCode = await runSai(
    args,
    stdIn: stdin,
    stdOut: stdout,
    stdErr: stderr,
  );
  if (exitCode != 0) {
    // ignore: avoid_print
    exit(exitCode);
  }
}
