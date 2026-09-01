import 'dart:convert';
import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

import '../../package_root.dart';

void main() {
  late Map<String, Object?> defs;
  late Set<String> clientMethods;
  late Set<String> serverNotifications;

  setUpAll(() async {
    final root = await packageRoot();
    final schema = jsonDecode(
      File(
        '${root.path}/test/llm/codex_app_server/fixtures/'
        'codex_app_server_protocol.v2.schemas.json',
      ).readAsStringSync(),
    ) as Map<String, Object?>;
    defs = schema['definitions'] as Map<String, Object?>;
    Set<String> methods(String union) => {
      for (final one in (defs[union] as Map<String, Object?>)['oneOf'] as List)
        ...(((one as Map<String, Object?>)['properties']
                    as Map<String, Object?>)['method']
                as Map<String, Object?>)['enum']
            as List,
    }.cast<String>();
    clientMethods = methods('ClientRequest');
    serverNotifications = methods('ServerNotification');
  });

  test('every method sai sends exists in the pinned schema', () {
    for (final m in CodexProtocol.clientMethods) {
      expect(clientMethods, contains(m), reason: m);
    }
    expect(CodexProtocol.release, 'rust-v0.152.0');
  });

  test('sai sends nothing that acts: no command, file, tool, plugin, '
      'skill, review, cloud or thread-store method', () {
    final forbidden = RegExp(
      r'^(command/|fs/|thread/shellCommand|thread/resume|thread/fork|'
      r'thread/list|thread/read|thread/turns|thread/items|thread/archive|'
      r'thread/delete|thread/compact|review/|skills/|plugin/|marketplace/|'
      r'app/|mcpServer|config/|externalAgentConfig|windowsSandbox|'
      r'feedback/|fuzzyFileSearch|turn/steer|thread/rollback|thread/revert|'
      r'account/login/start$)',
    );
    for (final m in CodexProtocol.clientMethods) {
      if (m == 'account/login/start') continue;
      expect(forbidden.hasMatch(m), isFalse, reason: m);
    }
  });

  test('every notification sai reads exists in the pinned schema', () {
    for (final n in CodexProtocol.acceptedNotifications) {
      expect(serverNotifications, contains(n), reason: n);
    }
  });

  test(
    'every server request sai declines is one the pinned README names',
    () async {
      // Server requests are not one union in the v2 schema; the README at
      // the same tag documents each by method name, and that text is the
      // fixture.
      final readme = File(
        '${(await packageRoot()).path}/test/llm/codex_app_server/fixtures/'
        'app-server-README.md',
      ).readAsStringSync();
      for (final method in CodexProtocol.serverRequests) {
        expect(readme, contains('`$method`'), reason: method);
      }
      // And the item the README documents for each active kind is one sai
      // refuses.
      for (final item in [
        'commandExecution',
        'fileChange',
        'mcpToolCall',
        'webSearch',
      ]) {
        expect(readme, contains('`$item`'), reason: item);
        expect(CodexProtocol.activeItems, contains(item));
      }
    },
  );

  test('every item type the schema knows is classified, passive or active', () {
    final item = defs['ThreadItem'] as Map<String, Object?>;
    final types = <String>{
      for (final one in item['oneOf'] as List)
        ...(((one as Map<String, Object?>)['properties']
                    as Map<String, Object?>)['type']
                as Map<String, Object?>)['enum']
            as List,
    }.cast<String>();
    for (final t in types) {
      expect(
        CodexProtocol.passiveItems.contains(t) ||
            CodexProtocol.activeItems.contains(t),
        isTrue,
        reason: 'unclassified item type $t — decide, do not guess',
      );
    }
    expect(
      CodexProtocol.passiveItems.intersection(CodexProtocol.activeItems),
      isEmpty,
    );
  });

  test('the sandbox and approval words are the schema\'s', () {
    final sandbox =
        (defs['SandboxMode'] as Map<String, Object?>)['enum'] as List;
    expect(sandbox, contains(CodexProtocol.sandboxReadOnly));
    final approval = defs['AskForApproval'] as Map<String, Object?>;
    final words =
        ((approval['oneOf'] as List).first as Map<String, Object?>)['enum']
            as List;
    expect(words, contains(CodexProtocol.approvalNever));
  });

  group('decoders', () {
    test('account/read', () {
      final signedIn = CodexAccount.fromJson({
        'account': {'type': 'chatgpt', 'email': 'a@b.c', 'planType': 'pro'},
        'requiresOpenaiAuth': true,
      });
      expect(signedIn.isChatGpt, isTrue);
      expect(signedIn.planType, 'pro');
      expect('$signedIn', isNot(contains('a@b.c')), reason: 'never printed');
      expect(
        CodexAccount.fromJson({'account': null, 'requiresOpenaiAuth': true})
            .type,
        CodexAccountType.none,
      );
      expect(
        CodexAccount.fromJson({
          'account': {'type': 'apiKey'},
        }).type,
        CodexAccountType.apiKey,
      );
      expect(
        CodexAccount.fromJson({
          'account': {'type': 'amazonBedrock'},
        }).type,
        CodexAccountType.other,
      );
      expect(CodexAccount.fromJson('garbage').type, CodexAccountType.none);
    });

    test('model/list keeps exact ids, names, efforts; drops hidden rows', () {
      final (models, cursor) = CodexModel.page({
        'data': [
          {
            'id': 'gpt-5.6-sol',
            'model': 'gpt-5.6-sol',
            'displayName': 'GPT-5.6 Sol',
            'description': 'd',
            'hidden': false,
            'isDefault': true,
            'defaultReasoningEffort': 'medium',
            'supportedReasoningEfforts': [
              {'reasoningEffort': 'low', 'description': 'fast'},
              {'reasoningEffort': 'xhigh', 'description': 'slow'},
            ],
          },
          {'model': 'secret', 'hidden': true, 'displayName': 's'},
          {'model': '', 'displayName': 'empty'},
          {
            'model': 'bare',
            'displayName': '',
            'hidden': false,
            'isDefault': false,
            'defaultReasoningEffort': 'none',
            'supportedReasoningEfforts': [],
          },
        ],
        'nextCursor': 'more',
      });
      expect(cursor, 'more');
      expect(models.map((m) => m.id), ['gpt-5.6-sol', 'bare']);
      final sol = models.first;
      expect(sol.displayName, 'GPT-5.6 Sol');
      expect(sol.isDefault, isTrue);
      expect(sol.defaultEffort, const ReasoningEffort('medium'));
      expect(sol.takes(const ReasoningEffort('xhigh')), isTrue);
      expect(sol.takes(const ReasoningEffort('high')), isFalse);
      expect(sol.supportedEfforts.last.description, 'slow');
      expect(
        models.last.displayName,
        'bare',
        reason: 'an empty name is the id',
      );
      expect(models.last.supportedEfforts, isEmpty);
      expect(CodexModel.page({'nope': 1}), (const <CodexModel>[], null));
    });

    test('login start: browser and device code', () {
      final browser = CodexLoginStart.fromJson({
        'type': 'chatgpt',
        'loginId': 'l1',
        'authUrl': 'https://chatgpt.com/auth?x',
      })!;
      expect(browser.isDeviceCode, isFalse);
      expect(browser.authUrl, startsWith('https://'));
      final device = CodexLoginStart.fromJson({
        'type': 'chatgptDeviceCode',
        'loginId': 'l2',
        'verificationUrl': 'https://auth.openai.com/codex/device',
        'userCode': 'ABCD-1234',
      })!;
      expect(device.isDeviceCode, isTrue);
      expect(device.userCode, 'ABCD-1234');
      expect(CodexLoginStart.fromJson({'type': 'chatgpt'}), isNull);
    });

    test('rate limits are plan state: percent and reset, never money', () {
      final limits = CodexRateLimits.fromJson({
        'rateLimits': {
          'primary': {
            'usedPercent': 25,
            'windowDurationMins': 300,
            'resetsAt': 1730947200,
          },
          'secondary': null,
          'planType': 'pro',
          'rateLimitReachedType': null,
          'spendControlReached': false,
        },
      });
      expect(limits.primary!.usedPercent, 25);
      expect(limits.primary!.windowMinutes, 300);
      expect(limits.primary!.resetsAt, DateTime.utc(2024, 11, 7, 2, 40));
      expect(limits.secondary, isNull);
      expect(limits.planType, 'pro');
      expect(limits.limitReached, isFalse);
      final reached = CodexRateLimits.fromJson({
        'rateLimits': {
          'primary': {'usedPercent': 100},
          'rateLimitReachedType': 'primary',
        },
      });
      expect(reached.limitReached, isTrue);
      // A sparse update has no wrapper.
      expect(
        CodexRateLimits.fromJson({
          'primary': {'usedPercent': 3},
        }).primary!.usedPercent,
        3,
      );
    });

    test('turn status, error class and usage', () {
      expect(codexTurnStatus('completed'), CodexTurnStatus.completed);
      expect(codexTurnStatus('interrupted'), CodexTurnStatus.interrupted);
      expect(codexTurnStatus('failed'), CodexTurnStatus.failed);
      expect(codexTurnStatus('inProgress'), CodexTurnStatus.inProgress);
      expect(codexTurnStatus('later'), CodexTurnStatus.unknown);
      expect(
        codexErrorClass({
          'message': 'x',
          'codexErrorInfo': 'usageLimitExceeded',
        }),
        CodexErrorClass.planLimit,
      );
      expect(
        codexErrorClass({
          'message': 'x',
          'codexErrorInfo': 'rateLimitExceeded',
        }),
        CodexErrorClass.planLimit,
      );
      expect(
        codexErrorClass({'message': 'x', 'codexErrorInfo': 'unauthorized'}),
        CodexErrorClass.unauthorized,
      );
      expect(
        codexErrorClass({'message': 'x', 'codexErrorInfo': 'serverOverloaded'}),
        CodexErrorClass.overloaded,
      );
      expect(
        codexErrorClass({
          'message': 'x',
          'codexErrorInfo': {
            'httpConnectionFailed': {'httpStatusCode': 502},
          },
        }),
        CodexErrorClass.other,
      );
      expect(codexErrorClass(null), CodexErrorClass.other);
      final usage = codexTurnUsage({
        'tokenUsage': {
          'last': {
            'inputTokens': 12,
            'outputTokens': 2,
            'totalTokens': 14,
            'cachedInputTokens': 0,
            'reasoningOutputTokens': 0,
          },
          'total': {
            'inputTokens': 99,
            'outputTokens': 9,
            'totalTokens': 108,
            'cachedInputTokens': 0,
            'reasoningOutputTokens': 0,
          },
        },
      })!;
      expect(
        (usage.promptTokens, usage.completionTokens, usage.totalTokens),
        (12, 2, 14),
      );
      expect(usage.cost, isNull);
      expect(codexTurnUsage({'tokenUsage': {}}), isNull);
    });
  });
}
