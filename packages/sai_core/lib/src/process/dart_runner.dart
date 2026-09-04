import 'dart:io';

import 'runner.dart';

/// The production [ProcessRunner]: `dart:io` with the parent environment
/// left out. Nothing else under `lib/` starts a process.
final class DartProcessRunner implements ProcessRunner {
  const DartProcessRunner();

  @override
  Future<RunningProcess> start(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    required String workingDirectory,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      environment: environment,
      includeParentEnvironment: false,
      workingDirectory: workingDirectory,
    );
    return _DartProcess(process);
  }
}

final class _DartProcess implements RunningProcess {
  _DartProcess(this._process);

  final Process _process;

  @override
  int get pid => _process.pid;

  @override
  IOSink get stdin => _process.stdin;

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) =>
      _process.kill(signal);
}
