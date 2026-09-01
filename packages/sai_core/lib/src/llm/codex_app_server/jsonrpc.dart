import 'dart:async';
import 'dart:convert';

import '../../process/runner.dart';
import 'text.dart';

/// Why a request to the App Server did not get its result.
final class JsonRpcException implements Exception {
  const JsonRpcException(this.text, {this.code, this.method});

  /// A [CodexText] word, never the server's own message.
  final String text;

  /// The JSON-RPC error code, when the server answered one.
  final int? code;

  /// The method that was being called.
  final String? method;

  /// The App Server's backpressure code: "Server overloaded; retry later."
  bool get isOverloaded => code == -32001;

  @override
  String toString() =>
      'JsonRpcException($text${code == null ? '' : ', code $code'}'
      '${method == null ? '' : ', $method'})';
}

/// A notification from the server: a method and its params.
final class JsonRpcNotification {
  const JsonRpcNotification(this.method, this.params);

  final String method;
  final Map<String, Object?> params;
}

/// A request from the server — an approval, a tool call, an input
/// request — which sai never services. The client has already answered
/// it with an error by the time it is reported; the report exists so the
/// runtime can stop the turn it belonged to.
final class JsonRpcServerRequest {
  const JsonRpcServerRequest(this.method, this.params);

  final String method;
  final Map<String, Object?> params;
}

/// Newline-delimited JSON-RPC 2.0 over a child's stdio, as the App Server
/// speaks it (the `jsonrpc` field omitted on the wire). One line is one
/// message; ids are integers of sai's own; a line with `id` and `method`
/// is a server request and is declined at once. Bounded: a line longer
/// than [maxLineBytes], more than [maxPending] requests in flight, or a
/// request that outlives its deadline is a failure in fixed words, and a
/// line that is not a JSON object ends the connection — the server is
/// not trusted to be well-formed. stderr is read to a bounded ring and
/// never surfaced: it is the vendor's diagnostics, not sai's.
final class JsonRpcClient {
  JsonRpcClient(
    this._process, {
    this.maxLineBytes = 1 << 20,
    this.maxPending = 8,
    this.requestTimeout = const Duration(seconds: 60),
  }) {
    _stdout = _process.stdout
        .transform(_BoundedLines(maxLineBytes))
        .listen(_onLine, onError: _onStreamError, onDone: _onStdoutDone);
    _stderr = _process.stderr.listen(_onStderr, onError: (_) {});
    unawaited(_process.exitCode.then(_onExit));
  }

  final RunningProcess _process;
  final int maxLineBytes;
  final int maxPending;
  final Duration requestTimeout;

  late final StreamSubscription<String> _stdout;
  late final StreamSubscription<List<int>> _stderr;
  final _pending = <int, _Pending>{};
  final _notifications = StreamController<JsonRpcNotification>.broadcast();
  final _serverRequests = StreamController<JsonRpcServerRequest>.broadcast();
  final _closed = Completer<String>();
  var _nextId = 1;
  var _stderrBytes = 0;

  /// The most of the child's stderr kept, for a person debugging with a
  /// debugger attached — never logged, never shown.
  static const maxStderrBytes = 64 << 10;
  final _stderrRing = <int>[];

  /// Server notifications, in order.
  Stream<JsonRpcNotification> get notifications => _notifications.stream;

  /// Server-initiated requests, each already declined.
  Stream<JsonRpcServerRequest> get serverRequests => _serverRequests.stream;

  /// Completes with a [CodexText] word once the connection is gone: the
  /// child exited, its stdout closed, or a line broke the protocol.
  Future<String> get closed => _closed.future;

  bool get isClosed => _closed.isCompleted;

  /// Sends [method] with [params] and awaits the result. Throws
  /// [JsonRpcException] for an error answer, a timeout, too many pending
  /// requests, or a connection that ended first.
  Future<Object?> request(
    String method,
    Map<String, Object?>? params, {
    Duration? timeout,
  }) {
    if (isClosed) {
      return Future.error(
        JsonRpcException(CodexText.childExited, method: method),
      );
    }
    if (_pending.length >= maxPending) {
      return Future.error(
        JsonRpcException(CodexText.tooManyPending, method: method),
      );
    }
    final id = _nextId++;
    final pending = _Pending(method);
    _pending[id] = pending;
    _send({'id': id, 'method': method, 'params': ?params});
    final deadline = Timer(timeout ?? requestTimeout, () {
      if (_pending.remove(id) case final p?) {
        p.completer.completeError(
          JsonRpcException(CodexText.timeout, method: method),
        );
      }
    });
    return pending.completer.future.whenComplete(deadline.cancel);
  }

  /// Sends a notification (no id, no answer).
  void notify(String method, Map<String, Object?>? params) {
    if (isClosed) return;
    _send({'method': method, 'params': ?params});
  }

  void _send(Map<String, Object?> message) {
    try {
      _process.stdin.write('${jsonEncode(message)}\n');
    } on Object {
      _end(CodexText.childExited);
    }
  }

  void _onLine(String line) {
    if (line.isEmpty) return;
    Object? json;
    try {
      json = jsonDecode(line);
    } on FormatException {
      return _end(CodexText.badLine);
    }
    if (json is! Map<String, Object?>) return _end(CodexText.badLine);
    final id = json['id'];
    final method = json['method'];
    if (method is String) {
      final params = json['params'];
      final map = params is Map<String, Object?>
          ? params
          : const <String, Object?>{};
      if (id != null) {
        // A request of the server's: declined before anything else is
        // told about it, so no approval can ever be inferred from
        // silence.
        _send({
          'id': id,
          'error': {'code': -32601, 'message': 'declined'},
        });
        _serverRequests.add(JsonRpcServerRequest(method, map));
      } else {
        _notifications.add(JsonRpcNotification(method, map));
      }
      return;
    }
    if (id is int) {
      final pending = _pending.remove(id);
      if (pending == null) return;
      final error = json['error'];
      if (error != null) {
        final code = error is Map<String, Object?> && error['code'] is int
            ? error['code'] as int
            : null;
        pending.completer.completeError(
          JsonRpcException(
            code == -32001 ? CodexText.overloaded : CodexText.rejected,
            code: code,
            method: pending.method,
          ),
        );
      } else {
        pending.completer.complete(json['result']);
      }
      return;
    }
    // A response to an id sai never sent, or a line with neither.
    _end(CodexText.badLine);
  }

  void _onStreamError(Object error) {
    _end(error is _LineTooLong ? CodexText.lineTooLong : CodexText.badLine);
  }

  void _onStdoutDone() => _end(CodexText.childExited);

  /// The exit can be seen before the last stdout bytes are read; stdout
  /// closing is what normally ends the connection, and this is the
  /// fallback for a child whose stdout never closes.
  void _onExit(int code) {
    Timer(const Duration(milliseconds: 500), () => _end(CodexText.childExited));
  }

  void _onStderr(List<int> bytes) {
    _stderrBytes += bytes.length;
    _stderrRing.addAll(bytes);
    if (_stderrRing.length > maxStderrBytes) {
      _stderrRing.removeRange(0, _stderrRing.length - maxStderrBytes);
    }
  }

  /// How much stderr the child has written; a number, never the text.
  int get stderrBytes => _stderrBytes;

  void _end(String why) {
    if (_closed.isCompleted) return;
    _closed.complete(why);
    for (final p in _pending.values) {
      p.completer.completeError(JsonRpcException(why, method: p.method));
    }
    _pending.clear();
    unawaited(_stdout.cancel().catchError((_) {}));
    unawaited(_stderr.cancel().catchError((_) {}));
    unawaited(_notifications.close());
    unawaited(_serverRequests.close());
  }

  /// Ends the connection from sai's side: stdin closed, pending requests
  /// failed with [CodexText.closed]. Does not touch the process.
  Future<void> close() async {
    _end(CodexText.closed);
    try {
      await _process.stdin.close();
    } on Object {
      // Already gone.
    }
  }
}

final class _Pending {
  _Pending(this.method);

  final String method;
  final completer = Completer<Object?>();
}

final class _LineTooLong implements Exception {
  const _LineTooLong();
}

/// UTF-8 bytes to lines, with a ceiling: a line that grows past
/// [maxBytes] without a newline errors the stream instead of buffering
/// without bound.
final class _BoundedLines extends StreamTransformerBase<List<int>, String> {
  const _BoundedLines(this.maxBytes);

  final int maxBytes;

  @override
  Stream<String> bind(Stream<List<int>> stream) async* {
    final buffer = <int>[];
    await for (final chunk in stream) {
      var start = 0;
      for (var i = 0; i < chunk.length; i++) {
        if (chunk[i] == 0x0a) {
          buffer.addAll(chunk.sublist(start, i));
          if (buffer.length > maxBytes) throw const _LineTooLong();
          yield utf8.decode(buffer, allowMalformed: true);
          buffer.clear();
          start = i + 1;
        }
      }
      if (start < chunk.length) buffer.addAll(chunk.sublist(start));
      if (buffer.length > maxBytes) throw const _LineTooLong();
    }
    if (buffer.isNotEmpty) yield utf8.decode(buffer, allowMalformed: true);
  }
}
