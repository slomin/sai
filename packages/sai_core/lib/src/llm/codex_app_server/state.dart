import '../failure.dart';
import 'protocol.dart';

/// Where a ChatGPT sign-in stands (#26). The runtime owns the flow; sai
/// shows only what it is told — a URL to open, a code to type — and
/// never a token.
enum ChatGptLoginPhase {
  /// No sign-in under way.
  idle,

  /// The browser flow: [ChatGptLogin.authUrl] was opened or shown.
  browser,

  /// The device-code flow: the person types [ChatGptLogin.userCode] at
  /// [ChatGptLogin.verificationUrl].
  deviceCode,

  /// The runtime said the login finished; the account is being re-read.
  completing,

  /// The runtime said the login did not complete.
  failed,

  /// Cancelled from sai.
  cancelled,
}

final class ChatGptLogin {
  const ChatGptLogin(
    this.phase, {
    this.loginId,
    this.authUrl,
    this.verificationUrl,
    this.userCode,
  });

  static const idle = ChatGptLogin(ChatGptLoginPhase.idle);

  final ChatGptLoginPhase phase;

  /// The runtime's id for this attempt; a completion for another id is
  /// a stale attempt's and is ignored.
  final String? loginId;
  final String? authUrl;
  final String? verificationUrl;
  final String? userCode;

  bool get inProgress =>
      phase == ChatGptLoginPhase.browser ||
      phase == ChatGptLoginPhase.deviceCode ||
      phase == ChatGptLoginPhase.completing;

  ChatGptLogin as(ChatGptLoginPhase phase) => ChatGptLogin(
    phase,
    loginId: loginId,
    authUrl: authUrl,
    verificationUrl: verificationUrl,
    userCode: userCode,
  );

  @override
  String toString() => 'ChatGptLogin(${phase.name})';
}

/// Everything both clients render for the ChatGPT subscription (#26):
/// who is signed in, the live model list with each model's efforts, the
/// plan's current limits, and the sign-in under way. Runtime state only —
/// none of it is written to settings, the archive or a log; the email
/// and the plan word live here and nowhere else.
final class ChatGptState {
  const ChatGptState({
    this.account,
    this.models,
    this.limits,
    this.loading = false,
    this.failure,
    this.login = ChatGptLogin.idle,
  });

  /// Who the runtime says is signed in; null before the first reading.
  final CodexAccount? account;

  /// The live model list, or null before the first successful reading.
  final List<CodexModel>? models;

  /// The plan's limits, or null before read.
  final CodexRateLimits? limits;

  /// Whether a reading is under way.
  final bool loading;

  /// How the last reading failed — signed out, in use elsewhere, no
  /// runtime; null after a success.
  final LlmFailure? failure;

  final ChatGptLogin login;

  /// Whether the session has tried to read at all.
  bool get attempted => account != null || failure != null || loading;

  bool get signedIn => account?.isChatGpt ?? false;

  /// The model with [id] as the list has it, or null when the list does
  /// not carry it — shown as unavailable, never swapped.
  CodexModel? modelNamed(String? id) =>
      id == null ? null : models?.where((m) => m.id == id).firstOrNull;

  /// The upstream-designated default, for first setup.
  CodexModel? get defaultModel =>
      models?.where((m) => m.isDefault).firstOrNull ?? models?.firstOrNull;

  ChatGptState copyWith({
    CodexAccount? Function()? account,
    List<CodexModel>? Function()? models,
    CodexRateLimits? Function()? limits,
    bool? loading,
    LlmFailure? Function()? failure,
    ChatGptLogin? login,
  }) => ChatGptState(
    account: account == null ? this.account : account(),
    models: models == null ? this.models : models(),
    limits: limits == null ? this.limits : limits(),
    loading: loading ?? this.loading,
    failure: failure == null ? this.failure : failure(),
    login: login ?? this.login,
  );

  @override
  String toString() =>
      'ChatGptState(${account == null ? 'unread' : account!.type.name}, '
      '${models?.length ?? 'no'} models${loading ? ', loading' : ''}'
      '${failure == null ? '' : ', ${failure!.message}'}, $login)';
}
