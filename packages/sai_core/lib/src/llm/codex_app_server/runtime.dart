import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../process/lock.dart';
import '../../process/runner.dart';
import '../call.dart';
import 'config.dart';
import 'jsonrpc.dart';
import 'protocol.dart';
import 'seatbelt.dart';
import 'sidecar.dart';
import 'text.dart';

/// Why the runtime could not do what was asked — a [CodexText] word and
/// the kind of failure it is for a call.
final class CodexException implements Exception {
  const CodexException(this.text, {this.credential = false});

  final String text;

  /// Whether this is a credential failure (signed out, wrong account,
  /// in use elsewhere, no runtime) rather than a protocol or transport
  /// one.
  final bool credential;

  @override
  String toString() => 'CodexException($text)';
}

/// Everything the App Server needs to be started with: where the binary
/// is, which home it owns, where its private temp root and the person's
/// keychains are, and the runner that starts it.
final class CodexLaunch {
  const CodexLaunch({
    required this.sidecar,
    required this.home,
    required this.tempRoot,
    required this.keychainsDir,
    required this.runner,
    this.clientVersion = '0',
    this.sandboxed = true,
    this.locale = 'en_US.UTF-8',
  });

  final SidecarLocator sidecar;
  final Directory home;

  /// A directory of sai's for the child's `TMPDIR` and for the per-call
  /// scratch directories; created 0700 when missing.
  final Directory tempRoot;

  /// The user's `~/Library/Keychains`, which the profile must open for
  /// the child's own `Codex Auth` item.
  final Directory keychainsDir;
  final ProcessRunner runner;
  final String clientVersion;

  /// Whether the child runs under `sandbox-exec`. Production always
  /// does; a test of the argv shape asserts both forms.
  final bool sandboxed;
  final String locale;

  /// The child's whole environment. Nothing of the parent's: a key in
  /// the shell (`OPENAI_API_KEY`, `CODEX_API_KEY`), a proxy, a custom
  /// base URL — none of it reaches the runtime (ADR 0013). `HOME` is the
  /// credential home too, so nothing of the person's is looked up by
  /// habit.
  Map<String, String> environment() => {
    'CODEX_HOME': home.path,
    'HOME': home.path,
    'TMPDIR': tempRoot.path,
    'LANG': locale,
    'RUST_LOG': 'warn',
    'PATH': '/usr/bin:/bin',
  };
}

/// One App Server child, owned for as long as the provider session lives
/// (#26): the lock on the credential home taken before the spawn and
/// released after the exit; the home prepared to the byte; the child
/// started under the Seatbelt profile with the minimal environment;
/// `initialize`/`initialized` once; then the account, login, model and
/// turn methods sai uses and no other. One child per runtime; one
/// runtime per home; the lock makes it one per machine.
final class AppServerRuntime {
  AppServerRuntime(
    this.launch, {
    this.graceOnCancel = const Duration(seconds: 2),
  });

  final CodexLaunch launch;

  /// How long an interrupted turn may take to say `turn/completed`
  /// before the child is terminated.
  final Duration graceOnCancel;

  /// How long the child gets to exit after SIGTERM before SIGKILL.
  static const terminateGrace = Duration(seconds: 3);

  _Session? _session;
  Future<_Session>? _starting;
  var _closed = false;
  var _busy = 0;

  /// Logins started and not yet completed or cancelled: each holds the
  /// child busy, so `releaseIdle` cannot end it while a person is still
  /// in the browser or typing a device code.
  final _pendingLogins = <String>{};
  final _loginBounds = <String, Timer>{};

  /// How long a started login may hold the child before it is let go
  /// unfinished — the runtime's own flow has expired by then.
  static const loginBound = Duration(minutes: 15);

  final _accountUpdates = StreamController<void>.broadcast();
  final _loginCompleted =
      StreamController<({String? loginId, bool success})>.broadcast();
  final _rateLimitUpdates = StreamController<CodexRateLimits>.broadcast();

  /// Fires on `account/updated`: whoever is signed in may have changed.
  Stream<void> get accountUpdates => _accountUpdates.stream;

  /// Fires on `account/login/completed`.
  Stream<({String? loginId, bool success})> get loginCompleted =>
      _loginCompleted.stream;

  /// Fires on `account/rateLimits/updated`, merged onto the last read.
  Stream<CodexRateLimits> get rateLimitUpdates => _rateLimitUpdates.stream;

  /// Whether a child is alive right now.
  bool get isRunning => _session != null && !_session!.rpc.isClosed;

  /// Whether a login or a turn is under way — what `releaseIdle` must
  /// not disturb.
  bool get isBusy => _busy > 0;

  /// The live child, started if need be. Throws [CodexException] with
  /// [CodexText.inUse] when another sai client holds the home,
  /// [CodexText.sidecarMissing] when there is no binary,
  /// [CodexText.startFailed] when it could not be started or would not
  /// initialize.
  Future<_Session> _ensure() {
    if (_closed) throw const CodexException(CodexText.closed);
    final live = _session;
    if (live != null && !live.rpc.isClosed) return Future.value(live);
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<_Session> _start() async {
    if (!launch.sidecar.exists) {
      throw const CodexException(CodexText.sidecarMissing, credential: true);
    }
    // The home, the temp root and the scratch root are the directories
    // the profile opens read-write: each is checked to be sai's own —
    // no symlink in its place, 0700 — on every start, not only the
    // first.
    final Directory home;
    final Directory scratchRoot;
    try {
      home = prepareCodexHome(launch.home);
      preparePrivateDir(launch.tempRoot);
      scratchRoot = preparePrivateDir(
        Directory(p.join(launch.tempRoot.path, 'scratch')),
      );
    } on FileSystemException {
      throw const CodexException(CodexText.homeUnsafe);
    }
    final lock = await ExclusiveLock.tryAcquire(
      File(p.join(home.path, 'lock')),
    );
    if (lock == null) {
      throw const CodexException(CodexText.inUse, credential: true);
    }
    final RunningProcess process;
    try {
      final sidecarArgs = const ['app-server'];
      process = launch.sandboxed
          ? await launch.runner.start(
              sandboxExec,
              seatbeltArguments(
                sidecar: launch.sidecar.executable,
                codexHome: home.path,
                scratch: scratchRoot.path,
                tmp: launch.tempRoot.path,
                keychains: launch.keychainsDir.path,
                sidecarArguments: sidecarArgs,
              ),
              environment: launch.environment(),
              workingDirectory: scratchRoot.path,
            )
          : await launch.runner.start(
              launch.sidecar.executable,
              sidecarArgs,
              environment: launch.environment(),
              workingDirectory: scratchRoot.path,
            );
    } on Object {
      await lock.release();
      throw const CodexException(CodexText.startFailed);
    }
    final rpc = JsonRpcClient(process);
    final session = _Session(process, rpc, lock, scratchRoot);
    unawaited(rpc.closed.then((_) => _onSessionEnded(session)));
    rpc.notifications.listen(_onNotification);
    try {
      final init = await rpc.request('initialize', {
        'clientInfo': {
          'name': 'sai',
          'title': 'sai',
          'version': launch.clientVersion,
        },
        'capabilities': {
          'optOutNotificationMethods': [
            'thread/status/changed',
            'turn/diff/updated',
            'turn/plan/updated',
            'item/plan/delta',
          ],
        },
      });
      // The server names the home it opened; anything but ours — or no
      // name at all — is a runtime that may have read another
      // configuration, and is not used.
      final opened = init is Map<String, Object?> && init['codexHome'] is String
          ? Directory(init['codexHome'] as String)
          : null;
      if (opened == null || _canonical(opened) != _canonical(home)) {
        throw const CodexException(CodexText.wrongHome, credential: true);
      }
      rpc.notify('initialized', null);
    } on Object catch (error) {
      await _terminate(session);
      if (error is CodexException) rethrow;
      throw const CodexException(CodexText.startFailed);
    }
    if (_closed) {
      // Closed while starting: the child that start produced ends here.
      await _terminate(session);
      throw const CodexException(CodexText.closed);
    }
    _session = session;
    return session;
  }

  static String _canonical(Directory dir) {
    try {
      return dir.resolveSymbolicLinksSync();
    } on FileSystemException {
      return p.normalize(dir.absolute.path);
    }
  }

  void _onNotification(JsonRpcNotification n) {
    switch (n.method) {
      case 'account/updated':
        _accountUpdates.add(null);
      case 'account/login/completed':
        final loginId = n.params['loginId'] is String
            ? n.params['loginId'] as String
            : null;
        _releaseLogin(loginId);
        _loginCompleted.add((
          loginId: loginId,
          success: n.params['success'] == true,
        ));
      case 'account/rateLimits/updated':
        _rateLimitUpdates.add(CodexRateLimits.fromJson(n.params));
    }
  }

  Future<void> _onSessionEnded(_Session session) async {
    if (identical(_session, session)) {
      _session = null;
      _releaseLogin(null);
    }
    await session.lock.release();
  }

  /// A started login holds the child busy until `account/login/completed`
  /// names it, it is cancelled, the child goes, or [loginBound] passes.
  void _ownLogin(String loginId) {
    _pendingLogins.add(loginId);
    _loginBounds.remove(loginId)?.cancel();
    _loginBounds[loginId] = Timer(loginBound, () => _releaseLogin(loginId));
  }

  /// Lets go of one pending login, or of all of them for null.
  void _releaseLogin(String? loginId) {
    final ids = loginId == null
        ? _pendingLogins.toList()
        : [if (_pendingLogins.contains(loginId)) loginId];
    for (final id in ids) {
      _pendingLogins.remove(id);
      _loginBounds.remove(id)?.cancel();
      _busy--;
    }
  }

  /// `account/read`: who is signed in, a fresh answer each time.
  Future<CodexAccount> account() async {
    final s = await _ensure();
    return CodexAccount.fromJson(
      await _call(s, 'account/read', {'refreshToken': false}),
    );
  }

  /// `account/login/start`: the browser URL or the device code — public
  /// values sai shows or opens; no token ever comes back this way. The
  /// child stays busy — never ended by `releaseIdle` — until the login
  /// completes, is cancelled, or [loginBound] passes.
  Future<CodexLoginStart> startLogin({required bool deviceCode}) async {
    final s = await _ensure();
    _busy++;
    var owned = false;
    try {
      final answer = await _call(s, 'account/login/start', {
        'type': deviceCode ? 'chatgptDeviceCode' : 'chatgpt',
      }, timeout: const Duration(seconds: 30));
      final start = CodexLoginStart.fromJson(answer);
      if (start == null) throw const CodexException(CodexText.loginFailed);
      _ownLogin(start.loginId);
      owned = true;
      return start;
    } finally {
      if (!owned) _busy--;
    }
  }

  /// `account/login/cancel` for [loginId].
  Future<void> cancelLogin(String loginId) async {
    final s = _session;
    if (s == null || s.rpc.isClosed) return;
    try {
      await _call(s, 'account/login/cancel', {'loginId': loginId});
    } on CodexException {
      // A login that already finished cannot be cancelled; that is fine.
    } finally {
      _releaseLogin(loginId);
    }
  }

  /// `account/logout`: the runtime clears its own store; sai touched
  /// nothing.
  Future<void> logout() async {
    final s = await _ensure();
    await _call(s, 'account/logout', null);
  }

  /// `model/list`, every page, hidden models left out.
  Future<List<CodexModel>> models() async {
    final s = await _ensure();
    final all = <CodexModel>[];
    String? cursor;
    var pages = 0;
    do {
      final answer = await _call(s, 'model/list', {'cursor': ?cursor});
      final (models, next) = CodexModel.page(answer);
      all.addAll(models);
      cursor = next;
      pages++;
    } while (cursor != null && pages < 20);
    return all;
  }

  /// `account/rateLimits/read`.
  Future<CodexRateLimits> rateLimits() async {
    final s = await _ensure();
    return CodexRateLimits.fromJson(
      await _call(s, 'account/rateLimits/read', null),
    );
  }

  Future<Object?> _call(
    _Session s,
    String method,
    Map<String, Object?>? params, {
    Duration? timeout,
  }) async {
    assert(CodexProtocol.clientMethods.contains(method), method);
    try {
      return await s.rpc.request(method, params, timeout: timeout);
    } on JsonRpcException catch (e) {
      throw CodexException(e.text);
    }
  }

  /// Runs one inference turn on a fresh, ephemeral thread and streams its
  /// deltas through [onText]/[onReasoning]; answers the turn's terminal
  /// outcome. [messages] is sai's governed order: the first leading
  /// system message is the thread's `baseInstructions`, every prior
  /// message is injected as a role-correct Responses item, and the last
  /// user message starts the turn. [cancelled] is polled to know when
  /// to interrupt.
  Future<CodexTurnOutcome> turn({
    required String model,
    required ReasoningEffort? effort,
    required List<LlmMessage> messages,
    Map<String, Object?>? outputSchema,
    required void Function(String) onText,
    required void Function(String) onReasoning,
    required Future<void> cancelled,
  }) async {
    final s = await _ensure();
    _busy++;
    Directory? scratch;
    try {
      scratch = Directory(
        p.join(
          s.scratchRoot.path,
          'turn-${DateTime.now().microsecondsSinceEpoch}',
        ),
      )..createSync(recursive: true);
      var index = 0;
      String? base;
      if (messages.first.role == LlmRole.system) {
        base = messages.first.text;
        index = 1;
      }
      final last = messages.length - 1;
      if (messages[last].role != LlmRole.user) {
        throw const CodexException(CodexText.rejected);
      }
      final thread = await _call(s, 'thread/start', {
        'model': model,
        'cwd': scratch.path,
        'approvalPolicy': CodexProtocol.approvalNever,
        'sandbox': CodexProtocol.sandboxReadOnly,
        'ephemeral': true,
        'baseInstructions': ?base,
        'config': codexThreadConfig,
      });
      final threadId = thread is Map<String, Object?>
          ? ((thread['thread'] as Map<String, Object?>?)?['id'] as String?)
          : null;
      if (threadId == null) throw const CodexException(CodexText.badLine);
      final actualModel =
          thread is Map<String, Object?> && thread['model'] is String
          ? thread['model'] as String
          : model;
      final history = <Map<String, Object?>>[];
      for (var i = index; i < last; i++) {
        history.add(_responsesItem(messages[i]));
      }
      if (history.isNotEmpty) {
        await _call(s, 'thread/inject_items', {
          'threadId': threadId,
          'items': history,
        });
      }
      final outcome = _TurnListener(
        s.rpc,
        threadId: threadId,
        onText: onText,
        onReasoning: onReasoning,
        initialModel: actualModel,
      );
      final started = await _call(s, 'turn/start', {
        'threadId': threadId,
        'input': [
          {'type': 'text', 'text': messages[last].text},
        ],
        'effort': ?effort?.word,
        'outputSchema': ?outputSchema,
      });
      final turnId = started is Map<String, Object?>
          ? ((started['turn'] as Map<String, Object?>?)?['id'] as String?)
          : null;
      if (turnId == null) {
        outcome.dispose();
        throw const CodexException(CodexText.badLine);
      }
      outcome.turnId = turnId;
      // Cancellation: interrupt, wait a little for the terminal event,
      // then terminate the child so no late delta can arrive.
      unawaited(
        cancelled.then((_) async {
          if (outcome.isDone) return;
          try {
            await _call(s, 'turn/interrupt', {
              'threadId': threadId,
              'turnId': turnId,
            });
          } on CodexException {
            // Then terminate below.
          }
          await Future.any([outcome.done, Future<void>.delayed(graceOnCancel)]);
          if (!outcome.isDone) await _terminate(s);
        }),
      );
      // An unsafe event: interrupt and let the failed outcome stand.
      outcome.onUnsafe = () {
        unawaited(
          _call(s, 'turn/interrupt', {
            'threadId': threadId,
            'turnId': turnId,
          }).catchError((_) => null),
        );
      };
      return await outcome.done;
    } finally {
      _busy--;
      if (scratch != null) {
        try {
          scratch.deleteSync(recursive: true);
        } on FileSystemException {
          // Reported by the caller as a cleanup note, never as a result.
        }
      }
    }
  }

  static Map<String, Object?> _responsesItem(LlmMessage m) => switch (m.role) {
    LlmRole.system => {
      'type': 'message',
      'role': 'developer',
      'content': [
        {'type': 'input_text', 'text': m.text},
      ],
    },
    LlmRole.user => {
      'type': 'message',
      'role': 'user',
      'content': [
        {'type': 'input_text', 'text': m.text},
      ],
    },
    LlmRole.assistant => {
      'type': 'message',
      'role': 'assistant',
      'content': [
        {'type': 'output_text', 'text': m.text},
      ],
    },
  };

  /// Ends an idle child and lets the lock go; a child in a login or a
  /// turn is left alone.
  Future<void> releaseIdle() async {
    if (isBusy) return;
    final s = _session;
    if (s == null) return;
    await _terminate(s);
  }

  /// Ends the runtime for good: the child terminated, the lock released,
  /// nothing started again.
  Future<void> close() async {
    _closed = true;
    // A start under way is joined, not raced: it sees the close and ends
    // the child it produced, or fails on its own.
    final starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } on Object {
        // Either way there is no live session to keep.
      }
    }
    final s = _session;
    if (s != null) await _terminate(s);
    await _accountUpdates.close();
    await _loginCompleted.close();
    await _rateLimitUpdates.close();
  }

  Future<void> _terminate(_Session s) async {
    if (identical(_session, s)) {
      _session = null;
      _releaseLogin(null);
    }
    await s.rpc.close();
    if (s.process.kill(ProcessSignal.sigterm)) {
      final exited = await Future.any([
        s.process.exitCode.then((_) => true),
        Future<void>.delayed(terminateGrace).then((_) => false),
      ]);
      if (!exited) s.process.kill(ProcessSignal.sigkill);
    }
    await s.lock.release();
  }
}

/// A live child: process, connection, lock and the scratch root.
final class _Session {
  _Session(this.process, this.rpc, this.lock, this.scratchRoot);

  final RunningProcess process;
  final JsonRpcClient rpc;
  final ExclusiveLock lock;
  final Directory scratchRoot;
}

/// How a turn ended: the status upstream said, the error class when it
/// failed, whether an unsafe event ended it, the usage and the model.
final class CodexTurnOutcome {
  const CodexTurnOutcome({
    required this.status,
    this.errorClass = CodexErrorClass.other,
    this.unsafe = false,
    this.usage,
    required this.model,
    this.turnId,
    this.protocolFailure,
  });

  final CodexTurnStatus status;

  /// The runtime's id for the turn — the lineage's request id.
  final String? turnId;
  final CodexErrorClass errorClass;
  final bool unsafe;
  final LlmUsage? usage;

  /// The model that answered, as `thread/start` or `model/rerouted` said.
  final String model;

  /// A [CodexText] word when the connection ended before the turn did.
  final String? protocolFailure;
}

/// Reads one turn's notifications off the connection: deltas for the
/// matching thread and turn only, the usage for that turn only, one
/// terminal `turn/completed`; any active item or server request stops it.
final class _TurnListener {
  _TurnListener(
    this.rpc, {
    required this.threadId,
    required this.onText,
    required this.onReasoning,
    required String initialModel,
  }) : _model = initialModel {
    _sub = rpc.notifications.listen(_on);
    _requests = rpc.serverRequests.listen((_) => _unsafe());
    unawaited(rpc.closed.then(_onClosed));
  }

  final JsonRpcClient rpc;
  final String threadId;
  String? turnId;
  final void Function(String) onText;
  final void Function(String) onReasoning;
  void Function()? onUnsafe;

  String _model;
  LlmUsage? _usage;
  var _unsafeSeen = false;
  CodexErrorClass _errorClass = CodexErrorClass.other;
  final _done = Completer<CodexTurnOutcome>();
  late final StreamSubscription<JsonRpcNotification> _sub;
  late final StreamSubscription<JsonRpcServerRequest> _requests;

  Future<CodexTurnOutcome> get done => _done.future;
  bool get isDone => _done.isCompleted;

  bool _mine(Map<String, Object?> params) {
    if (params['threadId'] != threadId) return false;
    final t = turnId;
    return t == null || params['turnId'] == null || params['turnId'] == t;
  }

  void _on(JsonRpcNotification n) {
    if (isDone) return;
    final params = n.params;
    switch (n.method) {
      case 'item/agentMessage/delta':
        if (_mine(params) && params['delta'] is String) {
          onText(params['delta'] as String);
        }
      case 'item/reasoning/summaryTextDelta':
      case 'item/reasoning/textDelta':
        if (_mine(params) && params['delta'] is String) {
          onReasoning(params['delta'] as String);
        }
      case 'item/started':
      case 'item/completed':
        if (!_mine(params)) return;
        final item = params['item'];
        final type = item is Map<String, Object?> ? item['type'] : null;
        if (type is! String || !CodexProtocol.passiveItems.contains(type)) {
          _unsafe();
        }
      case 'thread/tokenUsage/updated':
        if (_mine(params)) _usage = codexTurnUsage(params) ?? _usage;
      case 'model/rerouted':
        if (_mine(params) && params['toModel'] is String) {
          _model = params['toModel'] as String;
        }
      case 'error':
        if (_mine(params) && params['willRetry'] != true) {
          _errorClass = codexErrorClass(params['error']);
        }
      case 'turn/completed':
        if (params['threadId'] != threadId) return;
        final turn = params['turn'];
        if (turn is! Map<String, Object?>) return;
        if (turnId != null && turn['id'] != turnId) return;
        final status = codexTurnStatus(turn['status']);
        if (status == CodexTurnStatus.inProgress) return;
        final error = turn['error'];
        if (error != null) _errorClass = codexErrorClass(error);
        _finish(
          CodexTurnOutcome(
            status: status,
            errorClass: _errorClass,
            unsafe: _unsafeSeen,
            usage: _usage,
            model: _model,
            turnId: turnId,
          ),
        );
    }
  }

  void _unsafe() {
    if (isDone || _unsafeSeen) return;
    _unsafeSeen = true;
    onUnsafe?.call();
  }

  void _onClosed(String why) {
    if (isDone) return;
    _finish(
      CodexTurnOutcome(
        status: CodexTurnStatus.failed,
        unsafe: _unsafeSeen,
        usage: _usage,
        model: _model,
        turnId: turnId,
        protocolFailure: why,
      ),
    );
  }

  void _finish(CodexTurnOutcome outcome) {
    if (isDone) return;
    _done.complete(outcome);
    dispose();
  }

  void dispose() {
    unawaited(_sub.cancel());
    unawaited(_requests.cancel());
  }
}
