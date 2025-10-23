import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import 'core_contract.dart';
import 'context/context_collector.dart';
import 'init/generator.dart';

typedef StdStream = IOSink;

class SaiIo {
  SaiIo({
    required this.stdIn,
    required this.stdOut,
    required this.stdErr,
  });

  final Stdin stdIn;
  final StdStream stdOut;
  final StdStream stdErr;
}

Future<int> runSai(
  List<String> args, {
  required Stdin stdIn,
  required StdStream stdOut,
  required StdStream stdErr,
}) async {
  final cli = _SaiCli(SaiIo(stdIn: stdIn, stdOut: stdOut, stdErr: stdErr));
  return cli.run(args);
}

class _SaiCli {
  _SaiCli(this.io);

  final SaiIo io;

  Future<int> run(List<String> rawArgs) async {
    if (rawArgs.isNotEmpty &&
        (rawArgs.first == '-h' || rawArgs.first == '--help') &&
        rawArgs.length == 1) {
      _printUsage();
      return SaiExitCode.success;
    }

    if (rawArgs.isNotEmpty && rawArgs.first == 'init') {
      return _runInit(rawArgs.skip(1).toList());
    }

    if (rawArgs.isNotEmpty && rawArgs.first == 'doctor') {
      return _runDoctor(rawArgs.skip(1).toList());
    }

    return _runChat(rawArgs);
  }

  void _printUsage() {
    io.stdOut.writeln('Usage: sai [init|doctor|<free-form text>]');
    io.stdOut.writeln('  sai init <shell>   Print shell integration snippet');
    io.stdOut.writeln(
      '  sai doctor         Run diagnostics for shell integration/core',
    );
    io.stdOut.writeln('  sai <text>         Send natural language to sai-core');
  }

  Future<int> _runInit(List<String> args) async {
    final parser = ArgParser()
      ..addFlag(
        'help',
        abbr: 'h',
        negatable: false,
        help: 'Show help for init.',
      );
    ArgResults? results;
    try {
      results = parser.parse(args);
    } on FormatException catch (err) {
      io.stdErr.writeln('Error: ${err.message}');
      io.stdErr.writeln('Usage: sai init <zsh|bash>');
      return SaiExitCode.badInput;
    }

    if (results['help'] as bool) {
      io.stdOut.writeln('Usage: sai init <zsh|bash>');
      return SaiExitCode.success;
    }

    if (results.rest.isEmpty) {
      io.stdErr.writeln('Error: missing shell name. Try `sai init zsh`.');
      return SaiExitCode.badInput;
    }

    final shell = results.rest.first.toLowerCase();
    try {
      final snippet = generateShellInitSnippet(shell: shell);
      io.stdOut.writeln(snippet);
      return SaiExitCode.success;
    } on UnsupportedError catch (err) {
      io.stdErr.writeln('Error: ${err.message}');
      return SaiExitCode.badInput;
    }
  }

  Future<int> _runDoctor(List<String> args) async {
    final parser = ArgParser()
      ..addFlag(
        'help',
        abbr: 'h',
        negatable: false,
        help: 'Show help for doctor.',
      );
    ArgResults? results;
    try {
      results = parser.parse(args);
    } on FormatException catch (err) {
      io.stdErr.writeln('Error: ${err.message}');
      io.stdErr.writeln('Usage: sai doctor');
      return SaiExitCode.badInput;
    }

    if (results['help'] as bool) {
      io.stdOut.writeln('Usage: sai doctor');
      return SaiExitCode.success;
    }

    final collector = SaiContextCollector();
    final sb = StringBuffer();
    sb.writeln('sai doctor diagnostics');

    final coreCheck = await _checkSaiCore();
    sb.writeln('  sai-core: ${coreCheck.message}');

    final snapshot = collector.collectDirectorySnapshot();
    if (snapshot.error != null) {
      sb.writeln('  directory access: error ${snapshot.error}');
    } else {
      final sample = snapshot.entries.take(5).map((e) {
        final suffix = e.isDir ? '/' : '';
        return e.name + suffix;
      }).join(', ');
      sb.writeln('  directory sample: ${sample.isEmpty ? '(empty)' : sample}');
      if (snapshot.truncated) {
        sb.writeln('  directory sample truncated after ${snapshot.entries.length} entries');
      }
    }

    io.stdOut.write(sb.toString());
    if (!sb.toString().endsWith('\n')) {
      io.stdOut.writeln();
    }
    return coreCheck.exitCode;
  }

  Future<int> _runChat(List<String> args) async {
    final collector = SaiContextCollector();
    final invocation = await _parseChatInvocation(args, collector);

    if (invocation.message.trim().isEmpty) {
      io.stdErr.writeln(
        'No message provided. Try `sai how do I run tests?`',
      );
      return SaiExitCode.badInput;
    }

    final payload = await collector.collect(
      message: invocation.message,
      shell: invocation.shell,
      historyLines: invocation.history,
      historyProvided: invocation.historyProvided,
    );

    final process = await _startSaiCore();
    if (process == null) {
      return SaiExitCode.contextFailure;
    }

    await writePayloadJson(payload, sink: process.stdin);
    await process.stdin.close();

    unawaited(io.stdOut.addStream(process.stdout));
    unawaited(io.stdErr.addStream(process.stderr));

    final exitCode = await process.exitCode;
    return exitCode;
  }

  Future<Process?> _startSaiCore() async {
    try {
      return await Process.start(
        'sai-core',
        const ['--json', '@-'],
      );
    } on ProcessException catch (err) {
      io.stdErr.writeln(
        'Failed to start `sai-core`: ${err.message}. Make sure it is installed and on PATH.',
      );
      return null;
    }
  }

  Future<_DoctorCheckResult> _checkSaiCore() async {
    try {
      final process = await Process.start(
        'sai-core',
        const ['--version'],
      );
      final exitCode = await process.exitCode;
      if (exitCode == 0) {
        return _DoctorCheckResult(
          exitCode: SaiExitCode.success,
          message: 'found (version check succeeded)',
        );
      }
      return _DoctorCheckResult(
        exitCode: SaiExitCode.contextFailure,
        message: 'responded with exit code $exitCode',
      );
    } on ProcessException catch (err) {
      return _DoctorCheckResult(
        exitCode: SaiExitCode.contextFailure,
        message:
            'not found (${err.message}). Ensure sai-core is installed and on PATH.',
      );
    }
  }

  Future<_ChatInvocation> _parseChatInvocation(
    List<String> args,
    SaiContextCollector collector,
  ) async {
    String? shell;
    bool historyFromStdin = false;
    String? historyFileArg;

    var i = 0;
    List<String>? messageParts;
    while (i < args.length) {
      final arg = args[i];
      if (arg == '--') {
        messageParts = args.sublist(i + 1);
        break;
      } else if (arg == '--shell' && i + 1 < args.length) {
        shell = args[i + 1];
        i += 2;
        continue;
      } else if (arg.startsWith('--shell=')) {
        shell = arg.substring('--shell='.length);
        i += 1;
        continue;
      } else if (arg == '--history-stdin') {
        historyFromStdin = true;
        i += 1;
        continue;
      } else if (arg == '--history-file' && i + 1 < args.length) {
        historyFileArg = args[i + 1];
        i += 2;
        continue;
      } else if (arg.startsWith('--history-file=')) {
        historyFileArg = arg.substring('--history-file='.length);
        i += 1;
        continue;
      } else if (arg.startsWith('-')) {
        messageParts = args.sublist(i);
        break;
      } else {
        messageParts = args.sublist(i);
        break;
      }
    }

    messageParts ??= const [];

    List<String> historyLines = const [];
    var historyProvided = false;
    if (historyFromStdin) {
      final buffer = await utf8.decoder.bind(io.stdIn).join();
      historyLines = collector.parseRawHistory(buffer);
      historyProvided = buffer.trim().isNotEmpty;
    } else {
      final historyFile = historyFileArg ?? collector.historyFilePath;
      if (historyFile != null) {
        historyLines = await collector.loadHistoryFromFile(historyFile);
        historyProvided = historyLines.isNotEmpty;
      }
    }

    String message;
    if (messageParts.isNotEmpty) {
      message = messageParts.join(' ').trim();
    } else if (!historyFromStdin && !io.stdIn.hasTerminal) {
      message = (await utf8.decoder.bind(io.stdIn).join()).trim();
    } else {
      message = '';
    }

    return _ChatInvocation(
      message: message,
      shell: shell,
      history: historyLines,
      historyProvided: historyProvided,
    );
  }
}

class _DoctorCheckResult {
  _DoctorCheckResult({
    required this.exitCode,
    required this.message,
  });

  final int exitCode;
  final String message;
}

class _ChatInvocation {
  _ChatInvocation({
    required this.message,
    required this.shell,
    required this.history,
    required this.historyProvided,
  });

  final String message;
  final String? shell;
  final List<String> history;
  final bool historyProvided;
}
