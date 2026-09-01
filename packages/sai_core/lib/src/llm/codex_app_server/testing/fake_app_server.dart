import '../../../process/testing/scripted_runner.dart';

/// One model as the fake lists it.
Map<String, Object?> fakeModel(
  String id, {
  String? displayName,
  String defaultEffort = 'medium',
  List<String> efforts = const ['low', 'medium', 'high', 'xhigh'],
  bool isDefault = false,
  bool hidden = false,
}) => {
  'id': id,
  'model': id,
  'displayName': displayName ?? id,
  'description': 'about $id',
  'hidden': hidden,
  'isDefault': isDefault,
  'defaultReasoningEffort': defaultEffort,
  'supportedReasoningEfforts': [
    for (final e in efforts) {'reasoningEffort': e, 'description': 'desc $e'},
  ],
};

/// A scripted App Server (#26): answers the pinned methods the way the
/// real one would, from state a test sets — who is signed in, which
/// models exist, how a turn plays out. Nothing here is the real binary;
/// `no_spawn_test` pins that nothing under `test/` could be.
final class FakeAppServer {
  FakeAppServer({
    this.codexHome,
    this.account = const {
      'type': 'chatgpt',
      'email': 'person@example.com',
      'planType': 'pro',
    },
    List<Map<String, Object?>>? models,
  }) : models =
           models ??
           [
             fakeModel(
               'gpt-5.6-sol',
               displayName: 'GPT-5.6 Sol',
               isDefault: true,
             ),
             fakeModel(
               'gpt-5.6-luna',
               displayName: 'GPT-5.6 Luna',
               efforts: ['low', 'high'],
             ),
             fakeModel('gpt-5.6-hidden', hidden: true),
           ];

  /// What `initialize` reports as `codexHome`; null echoes the env.
  String? codexHome;

  /// The `account` of `account/read`; null is signed out.
  Map<String, Object?>? account;
  List<Map<String, Object?>> models;

  /// Every turn's words, in order; a turn plays [turnScript] instead when
  /// set.
  List<String> answer = ['ready', '.'];
  String? reasoning;

  /// Runs instead of the default streamed answer: emits whatever it
  /// wants for the turn.
  void Function(ScriptedProcess p, String threadId, String turnId)? turnScript;

  /// Turns started so far: `thread/start` and `turn/start` params.
  final threadStarts = <Map<String, Object?>>[];
  final injections = <Map<String, Object?>>[];
  final turnStarts = <Map<String, Object?>>[];
  final interrupts = <Map<String, Object?>>[];
  final logins = <Map<String, Object?>>[];
  final loginCancels = <Map<String, Object?>>[];
  var logouts = 0;
  var accountReads = 0;
  var modelLists = 0;
  var rateLimitReads = 0;

  /// The one runner tests hand to the runtime.
  late final runner = ScriptedRunner(script: _handle);

  var _threads = 0;
  var _turns = 0;
  var _logins = 0;

  void _handle(ScriptedProcess p, Map<String, Object?> line) {
    final id = line['id'];
    final method = line['method'];
    final params = (line['params'] as Map<String, Object?>?) ?? const {};
    if (method is! String) return;
    switch (method) {
      case 'initialize':
        p.reply(id, {
          'userAgent': 'codex_app_server/0.152.0 fake',
          'codexHome': codexHome ?? p.spawn.environment['CODEX_HOME'],
          'platformFamily': 'unix',
          'platformOs': 'macos',
        });
      case 'initialized':
        break;
      case 'account/read':
        accountReads++;
        p.reply(id, {'account': account, 'requiresOpenaiAuth': true});
      case 'account/login/start':
        _logins++;
        logins.add(params);
        final loginId = 'login-$_logins';
        if (params['type'] == 'chatgptDeviceCode') {
          p.reply(id, {
            'type': 'chatgptDeviceCode',
            'loginId': loginId,
            'verificationUrl': 'https://auth.openai.com/codex/device',
            'userCode': 'ABCD-1234',
          });
        } else {
          p.reply(id, {
            'type': 'chatgpt',
            'loginId': loginId,
            'authUrl': 'https://auth.openai.com/oauth/authorize?state=$loginId',
          });
        }
      case 'account/login/cancel':
        loginCancels.add(params);
        p.reply(id, {'status': 'canceled'});
        p.notify('account/login/completed', {
          'loginId': params['loginId'],
          'success': false,
          'error': 'cancelled',
        });
      case 'account/logout':
        logouts++;
        account = null;
        p.reply(id, {});
        p.notify('account/updated', {'authMode': null, 'planType': null});
      case 'account/rateLimits/read':
        rateLimitReads++;
        p.reply(id, {
          'rateLimits': {
            'primary': {
              'usedPercent': 25,
              'windowDurationMins': 300,
              'resetsAt': 1730947200,
            },
            'secondary': {'usedPercent': 5, 'windowDurationMins': 10080},
            'planType': 'pro',
            'rateLimitReachedType': null,
          },
        });
      case 'model/list':
        modelLists++;
        p.reply(id, {'data': models, 'nextCursor': null});
      case 'thread/start':
        threadStarts.add(params);
        _threads++;
        final threadId = 'thr_$_threads';
        p.reply(id, {
          'thread': {'id': threadId, 'ephemeral': true, 'path': null},
          'model': params['model'],
          'modelProvider': 'openai',
          'reasoningEffort': null,
          'approvalPolicy': 'never',
          'sandbox': {'type': 'readOnly'},
          'cwd': params['cwd'],
        });
        p.notify('thread/started', {
          'thread': {'id': threadId},
        });
      case 'thread/inject_items':
        injections.add(params);
        p.reply(id, {});
      case 'turn/start':
        turnStarts.add(params);
        _turns++;
        final threadId = params['threadId'] as String;
        final turnId = 'turn_$_turns';
        p.reply(id, {
          'turn': {'id': turnId, 'status': 'inProgress', 'items': []},
        });
        p.notify('turn/started', {
          'threadId': threadId,
          'turn': {'id': turnId, 'status': 'inProgress', 'items': []},
        });
        final script = turnScript;
        if (script != null) {
          script(p, threadId, turnId);
        } else {
          streamAnswer(p, threadId, turnId);
        }
      case 'turn/interrupt':
        interrupts.add(params);
        p.reply(id, {});
        p.notify('turn/completed', {
          'threadId': params['threadId'],
          'turn': {
            'id': params['turnId'],
            'status': 'interrupted',
            'items': [],
          },
        });
      default:
        p.fail(id, -32601, 'unknown method $method');
    }
  }

  /// The default turn: an agentMessage item, the reasoning summary when
  /// set, the words as deltas, usage, then `turn/completed`.
  void streamAnswer(ScriptedProcess p, String threadId, String turnId) {
    final scope = {'threadId': threadId, 'turnId': turnId};
    if (reasoning case final thought?) {
      p.notify('item/started', {
        ...scope,
        'item': {'type': 'reasoning', 'id': 'rs_1'},
        'startedAtMs': 1,
      });
      p.notify('item/reasoning/summaryTextDelta', {
        ...scope,
        'itemId': 'rs_1',
        'summaryIndex': 0,
        'delta': thought,
      });
      p.notify('item/completed', {
        ...scope,
        'item': {
          'type': 'reasoning',
          'id': 'rs_1',
          'summary': [thought],
        },
        'completedAtMs': 2,
      });
    }
    p.notify('item/started', {
      ...scope,
      'item': {'type': 'agentMessage', 'id': 'msg_1', 'text': ''},
      'startedAtMs': 3,
    });
    for (final word in answer) {
      p.notify('item/agentMessage/delta', {
        ...scope,
        'itemId': 'msg_1',
        'delta': word,
      });
    }
    p.notify('item/completed', {
      ...scope,
      'item': {'type': 'agentMessage', 'id': 'msg_1', 'text': answer.join()},
      'completedAtMs': 4,
    });
    p.notify('thread/tokenUsage/updated', {
      ...scope,
      'tokenUsage': {
        'last': {
          'inputTokens': 12,
          'cachedInputTokens': 0,
          'outputTokens': 2,
          'reasoningOutputTokens': 0,
          'totalTokens': 14,
        },
        'total': {
          'inputTokens': 12,
          'cachedInputTokens': 0,
          'outputTokens': 2,
          'reasoningOutputTokens': 0,
          'totalTokens': 14,
        },
        'modelContextWindow': 400000,
      },
    });
    p.notify('turn/completed', {
      'threadId': threadId,
      'turn': {
        'id': turnId,
        'status': 'completed',
        'items': [
          {'type': 'agentMessage', 'id': 'msg_1', 'text': answer.join()},
        ],
      },
    });
  }
}
