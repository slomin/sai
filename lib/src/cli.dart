import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import 'core_contract.dart';
import 'context/context_collector.dart';
import 'init/generator.dart';
import 'lm_client.dart';
import 'ui/ansi.dart';
import 'ui/spinner.dart';

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
        sb.writeln(
            '  directory sample truncated after ${snapshot.entries.length} entries');
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

    final start = DateTime.now();

    SaiSpinner? spinner;
    if (_shouldShowSpinner()) {
      spinner = SaiSpinner(
        sink: io.stdErr,
      )..start();
    }

    final lmResponse = await _queryLocalModel(
      collector: collector,
      payload: payload,
    );

    await spinner?.stop();

    if (lmResponse != null) {
      final duration = DateTime.now().difference(start);
      final exitCode = await _handleModelResponse(
        response: lmResponse,
        duration: duration,
      );
      if (exitCode != null) {
        return exitCode;
      }
    }

    final process = await _startSaiCore();
    if (process == null) {
      return SaiExitCode.contextFailure;
    }

    await writePayloadJson(payload, sink: process.stdin);
    await process.stdin.close();

    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();

    process.stdout.listen(
      io.stdOut.add,
      onDone: () {
        if (!stdoutDone.isCompleted) {
          stdoutDone.complete();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!stdoutDone.isCompleted) {
          stdoutDone.completeError(error, stackTrace);
        }
      },
      cancelOnError: true,
    );

    process.stderr.listen(
      io.stdErr.add,
      onDone: () {
        if (!stderrDone.isCompleted) {
          stderrDone.complete();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!stderrDone.isCompleted) {
          stderrDone.completeError(error, stackTrace);
        }
      },
      cancelOnError: true,
    );

    final exitCode = await process.exitCode;
    await stdoutDone.future;
    await stderrDone.future;
    final duration = DateTime.now().difference(start);
    io.stdOut.writeln(_formatTiming(duration));
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

  Future<SaiModelResponse?> _queryLocalModel({
    required SaiContextCollector collector,
    required SaiContextPayload payload,
  }) async {
    final env = Platform.environment;
    final config = SaiLmConfig.fromEnvironment(env);
    if (!config.enabled) {
      return null;
    }

    final snapshot = collector.collectDirectorySnapshot();
    final directoryLines = <String>[];
    if (snapshot.error != null) {
      directoryLines.add('  (error: ${snapshot.error})');
    } else if (snapshot.entries.isEmpty) {
      directoryLines.add('  (none)');
    } else {
      for (final entry in snapshot.entries.take(20)) {
        final suffix = entry.isDir ? '/' : '';
        directoryLines.add('  - ${entry.name}$suffix');
      }
      if (snapshot.truncated) {
        directoryLines.add('  - ...(truncated)');
      }
    }

    final historyLines = payload.history.isEmpty
        ? const ['  (none)']
        : payload.history.map((line) => '  - $line').toList();

    final cwdDescription = payload.cwd.isEmpty ? '(redacted)' : payload.cwd;
    final prompt = payload.message.isEmpty
        ? '(no direct prompt provided)'
        : payload.message;

    final sections = <String>[
      'User prompt: $prompt',
      '',
      'Context for you (zsh session):',
      '- Working directory to run commands from: $cwdDescription',
      '- Recent zsh commands (oldest -> newest):',
      ...historyLines,
      '- Visible files/folders in this directory (sample):',
      ...directoryLines,
      '',
      'Respond ONLY with compact JSON exactly in this form:',
      '{"explanation": "...", "recommended_command": "..."}',
      'Example: {"explanation": "List all files including hidden ones", "recommended_command": "ls -a"}',
      'Where "explanation" is a short description (max two sentences) and "recommended_command" is a single zsh command ready to run.',
      'Do not add code fences, additional keys, or commentary outside the JSON object.',
    ];

    final client = SaiLmClient(config: config);
    return client.complete(userPrompt: sections.join('\n'));
  }

  bool _shouldShowSpinner() {
    final env = Platform.environment;
    if (_isTruthy(env['SAI_NO_SPINNER'])) {
      return false;
    }
    return stderr.hasTerminal;
  }

  String _formatTiming(Duration duration) {
    final seconds = duration.inMilliseconds / 1000.0;
    return '[Total Response Time] ${seconds.toStringAsFixed(3)}s';
  }

  Future<int?> _handleModelResponse({
    required SaiModelResponse response,
    required Duration duration,
  }) async {
    if (response.hasStructured && _isMenuEnabled()) {
      await _presentInteractiveMenu(response);
      io.stdOut.writeln(_formatTiming(duration));
      return SaiExitCode.success;
    }

    final text = response.hasStructured
        ? '${_green('Explanation: ${response.explanation}')}'
            '\n'
            '${_green('Command: ${response.recommendedCommand}')}'
        : response.displayText.trim();

    if (text.trim().isNotEmpty) {
      io.stdOut.writeln(
        response.hasStructured ? text.trim() : _green(text.trim()),
      );
    }
    io.stdOut.writeln(_formatTiming(duration));
    return SaiExitCode.success;
  }

  bool _isMenuEnabled() {
    final env = Platform.environment;
    if (_isTruthy(env['SAI_NO_MENU'])) {
      return false;
    }
    if (!_hasInteractiveOutput()) {
      return false;
    }
    if (!stdin.hasTerminal && !_hasTty()) {
      return false;
    }
    return true;
  }

  Future<void> _presentInteractiveMenu(SaiModelResponse response) async {
    final explanation = response.explanation?.trim() ?? '';
    final command = response.recommendedCommand?.trim() ?? '';

    io.stdOut
      ..writeln(_green('Pick your answer:'))
      ..writeln(_green('  1) Explanation'))
      ..writeln('     ${_green(_preview(explanation))}')
      ..writeln(_green('  2) Command'))
      ..writeln('     ${_green(_preview(command))}')
      ..writeln(_green('  0) Cancel'));

    int? choice;
    while (choice == null) {
      final line = _readLine('Select [0-2]: ');
      if (line == null) {
        break;
      }
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final parsed = int.tryParse(trimmed);
      if (parsed == null || parsed < 0 || parsed > 2) {
        continue;
      }
      choice = parsed;
    }

    if (choice == null || choice == 0) {
      io.stdErr.writeln(_green('↳ Selection cancelled.'));
      return;
    }

    final text = choice == 1 ? '# $explanation' : command;
    await _applySelection(text.trim(), choice == 1 ? 'explanation' : 'command');
  }

  String _preview(String text) {
    final firstLine = text.split('\n').first.trim();
    const maxLen = 70;
    if (firstLine.isEmpty) {
      return '(empty)';
    }
    if (firstLine.length <= maxLen) {
      return firstLine;
    }
    return '${firstLine.substring(0, maxLen - 1)}…';
  }

  Future<void> _applySelection(String text, String label) async {
    if (text.isEmpty) {
      io.stdErr.writeln(_green('↳ Nothing to insert for $label.'));
      return;
    }

    final inserted = await _insertIntoPrompt(text);
    var copied = false;
    if (!inserted) {
      copied = await _copyToClipboard(text);
    }

    if (inserted) {
      io.stdErr.writeln(
          _green('↳ Inserted $label into prompt. Press Enter to run.'));
    } else if (copied) {
      io.stdErr.writeln(_green('↳ Copied $label to clipboard.'));
    } else {
      io.stdOut.writeln(_green(text));
    }
  }

  Future<bool> _insertIntoPrompt(String text) async {
    if (!_hasInteractiveOutput()) {
      return false;
    }
    final sanitized = text.replaceAll('\u001B', '');
    try {
      await _writeToTerminal('\u001B[200~$sanitized\u001B[201~');
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _copyToClipboard(String text) async {
    final env = Platform.environment;
    if (_isTruthy(env['SAI_NO_CLIPBOARD'])) {
      return false;
    }
    try {
      final process = await Process.start('pbcopy', const []);
      process.stdin
        ..write(text)
        ..close();
      final exitCode = await process.exitCode;
      return exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static bool _isTruthy(String? value) {
    if (value == null) {
      return false;
    }
    final normalized = value.trim().toLowerCase();
    return normalized == '1' ||
        normalized == 'true' ||
        normalized == 'yes' ||
        normalized == 'on';
  }

  bool _hasInteractiveOutput() {
    if (_stdoutHasTerminal()) {
      return true;
    }
    return _hasTty();
  }

  bool _hasTty() {
    if (io.stdOut is Stdout && (io.stdOut as Stdout).hasTerminal) {
      return true;
    }
    if (io.stdIn.hasTerminal) {
      return true;
    }
    try {
      return File('/dev/tty').existsSync();
    } catch (_) {
      return false;
    }
  }

  bool _stdoutHasTerminal() {
    return io.stdOut is Stdout && (io.stdOut as Stdout).hasTerminal;
  }

  Future<void> _writeToTerminal(String text) async {
    if (_stdoutHasTerminal()) {
      io.stdOut.write(text);
      await io.stdOut.flush();
      return;
    }
    try {
      File('/dev/tty').writeAsStringSync(
        text,
        mode: FileMode.append,
      );
    } catch (_) {
      // ignore
    }
  }

  String? _readLine(String prompt) {
    _writeToTerminalSync(prompt);
    if (io.stdIn.hasTerminal) {
      return io.stdIn.readLineSync();
    }
    try {
      final tty = File('/dev/tty');
      if (!tty.existsSync()) {
        return null;
      }
      final raf = tty.openSync(mode: FileMode.read);
      final bytes = <int>[];
      while (true) {
        int byte;
        try {
          byte = raf.readByteSync();
        } on FileSystemException {
          raf.closeSync();
          return null;
        }
        if (byte == 10) {
          break;
        }
        if (byte == 13) {
          final next = raf.readByteSync();
          if (next != 10) {
            bytes.add(next);
          }
          break;
        }
        bytes.add(byte);
      }
      raf.closeSync();
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  void _writeToTerminalSync(String text) {
    if (_stdoutHasTerminal()) {
      io.stdOut.write(text);
      io.stdOut.flush();
      return;
    }
    try {
      File('/dev/tty').writeAsStringSync(
        text,
        mode: FileMode.append,
      );
    } catch (_) {
      // ignore
    }
  }

  String _green(String text) => Ansi.wrap(text, Ansi.green);
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
