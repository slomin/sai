import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../runner.dart';

/// What a fake child was started with — what every runtime test asserts
/// on: the executable, the arguments, the environment it got and no
/// other, the working directory.
final class Spawn {
  Spawn(
    this.executable,
    this.arguments,
    this.environment,
    this.workingDirectory,
  );

  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final String workingDirectory;
}

/// A scripted child: every line the runtime writes to its stdin is
/// parsed as JSON and handed to [onLine], which answers by writing lines
/// back with [emit], or does nothing. Exit is the test's to decide.
final class ScriptedProcess implements RunningProcess {
  ScriptedProcess({required this.spawn, this.onLine, this.pid = 4242}) {
    _stdinSink = _LineSink(this);
  }

  final Spawn spawn;
  @override
  final int pid;

  /// Called with each parsed stdin line, in order.
  void Function(ScriptedProcess process, Map<String, Object?> line)? onLine;

  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exit = Completer<int>();
  late final _LineSink _stdinSink;

  /// Every line the runtime wrote, parsed.
  final written = <Map<String, Object?>>[];

  /// Raw stdin text that was not JSON (a protocol bug in the runtime).
  final malformed = <String>[];

  /// Signals sent.
  final signals = <ProcessSignal>[];

  @override
  IOSink get stdin => _stdinSink;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  bool get exited => _exit.isCompleted;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (exited) return false;
    signals.add(signal);
    return true;
  }

  /// Breaks stdin the way a dead child's pipe does: `stdin.done` fails
  /// with [error]; writes go nowhere.
  void breakStdin(Object error) => _stdinSink._break(error);

  /// Writes one JSON line to the runtime, as the App Server would.
  void emit(Map<String, Object?> line) => emitRaw('${jsonEncode(line)}\n');

  /// Writes raw bytes to stdout — a fragment, a torn line, garbage.
  void emitRaw(String text) {
    if (!_stdout.isClosed) _stdout.add(utf8.encode(text));
  }

  void emitStderr(String text) {
    if (!_stderr.isClosed) _stderr.add(utf8.encode(text));
  }

  /// Answers the request [id] with [result].
  void reply(Object? id, Object? result) => emit({'id': id, 'result': result});

  /// Answers the request [id] with a JSON-RPC error.
  void fail(Object? id, int code, String message) => emit({
    'id': id,
    'error': {'code': code, 'message': message},
  });

  /// Sends a notification.
  void notify(String method, Map<String, Object?> params) =>
      emit({'method': method, 'params': params});

  /// Sends a server-initiated request the runtime must decline.
  void ask(Object id, String method, Map<String, Object?> params) =>
      emit({'id': id, 'method': method, 'params': params});

  /// Ends the child with [code]: stdout and stderr close, exit completes.
  void exit(int code) {
    if (exited) return;
    _stdout.close();
    _stderr.close();
    _exit.complete(code);
  }

  void _line(String text) {
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      malformed.add(text);
      return;
    }
    if (json is! Map<String, Object?>) {
      malformed.add(text);
      return;
    }
    written.add(json);
    onLine?.call(this, json);
  }
}

/// Splits what the runtime writes into lines; a sink the runtime can
/// treat as stdin.
final class _LineSink implements IOSink {
  _LineSink(this._process);

  final ScriptedProcess _process;
  final _buffer = StringBuffer();
  final _done = Completer<void>();

  var _broken = false;

  void _break(Object error) {
    _broken = true;
    if (!_done.isCompleted) _done.completeError(error);
  }

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {
    if (_broken) return;
    _buffer.write(utf8.decode(data));
    var text = _buffer.toString();
    var at = text.indexOf('\n');
    while (at >= 0) {
      _process._line(text.substring(0, at));
      text = text.substring(at + 1);
      at = text.indexOf('\n');
    }
    _buffer
      ..clear()
      ..write(text);
  }

  @override
  void write(Object? object) => add(utf8.encode('$object'));

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}

/// The fake [ProcessRunner]: records every spawn, hands each a
/// [ScriptedProcess] driven by [script]. A test reads [spawns] to assert
/// argv, environment and cwd, and [processes] to drive stdout.
final class ScriptedRunner implements ProcessRunner {
  ScriptedRunner({this.script, this.startError});

  /// Installed on every new process as its `onLine`.
  void Function(ScriptedProcess process, Map<String, Object?> line)? script;

  /// When set, `start` throws it — a missing or unrunnable executable.
  Object? startError;

  final spawns = <Spawn>[];
  final processes = <ScriptedProcess>[];

  @override
  Future<RunningProcess> start(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    required String workingDirectory,
  }) async {
    final spawn = Spawn(executable, arguments, environment, workingDirectory);
    spawns.add(spawn);
    if (startError case final error?) throw error;
    final process = ScriptedProcess(spawn: spawn, onLine: script);
    processes.add(process);
    return process;
  }
}
