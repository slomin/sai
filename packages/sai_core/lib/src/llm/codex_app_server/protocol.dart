import '../call.dart';

/// The App Server protocol as sai uses it (#26), pinned to Codex
/// `rust-v0.152.0` — the README and the v2 JSON schema at that tag are
/// the fixtures under `test/llm/codex_app_server/fixtures/`. Allowlists,
/// not guesses: sai sends these methods and no other, reads these
/// notifications and no other, declines every server-initiated request,
/// and fails a turn closed on any item that is not passive text. An
/// upstream upgrade is its own change: re-diff the schema, re-run the
/// suite, move the pin.
abstract final class CodexProtocol {
  /// The pinned upstream release.
  static const release = 'rust-v0.152.0';

  /// Methods sai sends. Nothing that runs a command, touches a file,
  /// calls a tool, reads a thread store or manages plugins is here.
  static const clientMethods = {
    'initialize',
    'account/read',
    'account/login/start',
    'account/login/cancel',
    'account/logout',
    'account/rateLimits/read',
    'model/list',
    'thread/start',
    'thread/inject_items',
    'turn/start',
    'turn/interrupt',
  };

  /// The one notification sai sends.
  static const clientNotifications = {'initialized'};

  /// Notifications sai reads; every other one is passive and ignored.
  static const acceptedNotifications = {
    'account/updated',
    'account/login/completed',
    'account/rateLimits/updated',
    'thread/started',
    'turn/started',
    'turn/completed',
    'item/started',
    'item/completed',
    'item/agentMessage/delta',
    'item/reasoning/summaryTextDelta',
    'item/reasoning/textDelta',
    'thread/tokenUsage/updated',
    'model/rerouted',
    'error',
  };

  /// Server-initiated requests the pinned server can send. Each is
  /// answered with a JSON-RPC error and the running turn is stopped;
  /// sai services no approval, no input request, no tool call.
  static const serverRequests = {
    'item/commandExecution/requestApproval',
    'item/fileChange/requestApproval',
    'item/tool/requestUserInput',
    'item/permissions/requestApproval',
    'item/tool/call',
    'mcpServer/elicitation/request',
    'attestation/generate',
    'currentTime/read',
  };

  /// Item types that are text sai asked for, or bookkeeping.
  static const passiveItems = {
    'userMessage',
    'agentMessage',
    'reasoning',
    'contextCompaction',
    'compacted',
    'sleep',
  };

  /// Item types that mean the runtime is acting, not answering. Any of
  /// these — and any type sai has never heard of — ends the turn.
  static const activeItems = {
    'commandExecution',
    'fileChange',
    'mcpToolCall',
    'collabToolCall',
    'collabAgentToolCall',
    'subAgentActivity',
    'webSearch',
    'imageGeneration',
    'imageView',
    'plan',
    'enteredReviewMode',
    'exitedReviewMode',
    'functionCallOutput',
    'hookPrompt',
    'dynamicToolCall',
  };

  /// The `sandbox` word for a thread that may read nothing but its own
  /// scratch directory and write nothing at all.
  static const sandboxReadOnly = 'read-only';

  /// The `approvalPolicy` word for a thread sai never approves anything on.
  static const approvalNever = 'never';
}

/// Who the App Server says is signed in (`account/read`).
enum CodexAccountType { none, chatgpt, apiKey, other }

final class CodexAccount {
  const CodexAccount(this.type, {this.planType, this.email});

  final CodexAccountType type;

  /// The plan word (`plus`, `pro`, …) — UI state only, never stored.
  final String? planType;

  /// Shown in the current UI state only — never settings, archive or a
  /// log line.
  final String? email;

  bool get isChatGpt => type == CodexAccountType.chatgpt;

  static CodexAccount fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      return const CodexAccount(CodexAccountType.none);
    }
    final account = json['account'];
    if (account is! Map<String, Object?>) {
      return const CodexAccount(CodexAccountType.none);
    }
    return switch (account['type']) {
      'chatgpt' => CodexAccount(
        CodexAccountType.chatgpt,
        planType: account['planType'] is String
            ? account['planType'] as String
            : null,
        email: account['email'] is String ? account['email'] as String : null,
      ),
      'apiKey' => const CodexAccount(CodexAccountType.apiKey),
      null => const CodexAccount(CodexAccountType.none),
      _ => const CodexAccount(CodexAccountType.other),
    };
  }

  @override
  String toString() =>
      'CodexAccount(${type.name}'
      '${planType == null ? '' : ', $planType'})';
}

/// One reasoning effort a model advertises, with upstream's description.
final class CodexEffortOption {
  const CodexEffortOption(this.effort, {this.description = ''});

  final ReasoningEffort effort;
  final String description;
}

/// One model as `model/list` describes it: the exact id sai stores and
/// sends, the name it shows, the default effort and the efforts it takes.
/// Nothing is inferred from the id.
final class CodexModel {
  const CodexModel({
    required this.id,
    required this.displayName,
    this.description = '',
    this.isDefault = false,
    this.defaultEffort,
    this.supportedEfforts = const [],
  });

  /// The `model` field — what goes on the wire and into settings.
  final String id;
  final String displayName;
  final String description;

  /// Upstream's designated default; preselected on first setup.
  final bool isDefault;

  /// The effort upstream applies when none is sent, for "Model default
  /// (`<word>`)".
  final ReasoningEffort? defaultEffort;

  /// The efforts this model takes; empty when upstream lists none, in
  /// which case only Model default is offered.
  final List<CodexEffortOption> supportedEfforts;

  bool takes(ReasoningEffort effort) =>
      supportedEfforts.any((o) => o.effort == effort);

  static CodexModel? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['model'];
    if (id is! String || id.isEmpty) return null;
    final name = json['displayName'];
    final efforts = <CodexEffortOption>[];
    if (json['supportedReasoningEfforts'] case final List list) {
      for (final option in list) {
        if (option is Map<String, Object?> &&
            option['reasoningEffort'] is String &&
            (option['reasoningEffort'] as String).isNotEmpty) {
          efforts.add(
            CodexEffortOption(
              ReasoningEffort(option['reasoningEffort'] as String),
              description: option['description'] is String
                  ? option['description'] as String
                  : '',
            ),
          );
        }
      }
    }
    return CodexModel(
      id: id,
      displayName: name is String && name.isNotEmpty ? name : id,
      description: json['description'] is String
          ? json['description'] as String
          : '',
      isDefault: json['isDefault'] == true,
      defaultEffort: ReasoningEffort.parse(
        json['defaultReasoningEffort'] is String
            ? json['defaultReasoningEffort'] as String
            : null,
      ),
      supportedEfforts: efforts,
    );
  }

  /// The models of one `model/list` page, hidden ones left out, and the
  /// cursor for the next page or null.
  static (List<CodexModel>, String?) page(Object? json) {
    if (json is! Map<String, Object?> || json['data'] is! List) {
      return (const [], null);
    }
    final models = <CodexModel>[];
    for (final row in json['data'] as List) {
      if (row is Map<String, Object?> && row['hidden'] == true) continue;
      final model = fromJson(row);
      if (model != null) models.add(model);
    }
    final cursor = json['nextCursor'];
    return (models, cursor is String && cursor.isNotEmpty ? cursor : null);
  }
}

/// What `account/login/start` answered: the browser URL to open, or the
/// device code and where to enter it — public values, never a token.
final class CodexLoginStart {
  const CodexLoginStart({
    required this.loginId,
    this.authUrl,
    this.verificationUrl,
    this.userCode,
  });

  final String loginId;
  final String? authUrl;
  final String? verificationUrl;
  final String? userCode;

  bool get isDeviceCode => userCode != null;

  static CodexLoginStart? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final id = json['loginId'];
    if (id is! String || id.isEmpty) return null;
    String? s(String key) => json[key] is String ? json[key] as String : null;
    return CodexLoginStart(
      loginId: id,
      authUrl: s('authUrl'),
      verificationUrl: s('verificationUrl'),
      userCode: s('userCode'),
    );
  }
}

/// One rate-limit window as upstream reports it: how much of the window
/// is used and when it resets. Plan state, not API quota, never money.
final class CodexRateWindow {
  const CodexRateWindow({
    required this.usedPercent,
    this.windowMinutes,
    this.resetsAt,
  });

  final int usedPercent;
  final int? windowMinutes;
  final DateTime? resetsAt;

  static CodexRateWindow? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final used = json['usedPercent'];
    if (used is! num) return null;
    final minutes = json['windowDurationMins'];
    final resets = json['resetsAt'];
    return CodexRateWindow(
      usedPercent: used.toInt(),
      windowMinutes: minutes is num ? minutes.toInt() : null,
      resetsAt: resets is num
          ? DateTime.fromMillisecondsSinceEpoch(
              resets.toInt() * 1000,
              isUtc: true,
            )
          : null,
    );
  }
}

/// The plan's current limits (`account/rateLimits/read` and its
/// updates).
final class CodexRateLimits {
  const CodexRateLimits({
    this.primary,
    this.secondary,
    this.planType,
    this.limitReached = false,
  });

  final CodexRateWindow? primary;
  final CodexRateWindow? secondary;
  final String? planType;

  /// Whether upstream says a limit or spend control is reached now.
  final bool limitReached;

  static CodexRateLimits fromJson(Object? json) {
    if (json is! Map<String, Object?>) return const CodexRateLimits();
    final limits = json['rateLimits'];
    final body = limits is Map<String, Object?> ? limits : json;
    return CodexRateLimits(
      primary: CodexRateWindow.fromJson(body['primary']),
      secondary: CodexRateWindow.fromJson(body['secondary']),
      planType: body['planType'] is String ? body['planType'] as String : null,
      limitReached:
          body['rateLimitReachedType'] != null ||
          body['spendControlReached'] == true,
    );
  }
}

/// How a turn ended, as `turn/completed` says.
enum CodexTurnStatus { completed, interrupted, failed, inProgress, unknown }

CodexTurnStatus codexTurnStatus(Object? word) => switch (word) {
  'completed' => CodexTurnStatus.completed,
  'interrupted' => CodexTurnStatus.interrupted,
  'failed' => CodexTurnStatus.failed,
  'inProgress' => CodexTurnStatus.inProgress,
  _ => CodexTurnStatus.unknown,
};

/// The `codexErrorInfo` word of a failed turn, reduced to the few
/// classes sai answers differently.
enum CodexErrorClass { planLimit, unauthorized, overloaded, other }

CodexErrorClass codexErrorClass(Object? error) {
  if (error is! Map<String, Object?>) return CodexErrorClass.other;
  final info = error['codexErrorInfo'];
  final word = info is String
      ? info
      : info is Map<String, Object?> && info.isNotEmpty
      ? info.keys.first
      : '';
  return switch (word) {
    'usageLimitExceeded' ||
    'rateLimitExceeded' ||
    'sessionBudgetExceeded' => CodexErrorClass.planLimit,
    'unauthorized' => CodexErrorClass.unauthorized,
    'serverOverloaded' => CodexErrorClass.overloaded,
    _ => CodexErrorClass.other,
  };
}

/// Token usage of one turn (`thread/tokenUsage/updated`, `last`).
LlmUsage? codexTurnUsage(Object? json) {
  if (json is! Map<String, Object?>) return null;
  final usage = json['tokenUsage'];
  final last = usage is Map<String, Object?> ? usage['last'] : null;
  if (last is! Map<String, Object?>) return null;
  int? n(String key) => last[key] is num ? (last[key] as num).toInt() : null;
  final input = n('inputTokens');
  final output = n('outputTokens');
  final total = n('totalTokens');
  if (input == null && output == null && total == null) return null;
  return LlmUsage(
    promptTokens: input,
    completionTokens: output,
    totalTokens: total,
  );
}
