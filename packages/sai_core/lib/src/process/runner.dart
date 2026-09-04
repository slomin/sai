import 'dart:async';
import 'dart:io';

/// The one way sai starts a child process (#26, ADR 0013): a vendor
/// runtime speaking JSON-RPC over stdio. The interface has no way to
/// inherit the parent's environment — a caller hands over exactly the
/// variables the child gets, so a key in the shell can never bill a
/// subscription call — and production has one implementation,
/// [DartProcessRunner] beside this file, the only `Process.start` in
/// `lib/` (`test/no_spawn_test.dart` pins it). Every test scripts a fake.
abstract interface class ProcessRunner {
  Future<RunningProcess> start(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    required String workingDirectory,
  });
}

/// A child sai started: its stdio and its exit.
abstract interface class RunningProcess {
  int get pid;

  /// Bytes to the child's stdin.
  IOSink get stdin;

  /// The child's stdout and stderr, as bytes, single-subscription.
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;

  /// The exit code, once.
  Future<int> get exitCode;

  /// Sends [signal]; false when the child is already gone.
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);
}
