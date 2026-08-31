import 'call.dart';

/// Where a provider's inference happens — the tag the privacy policy
/// (#27) checks before a request is built. The LAN counts as local (#22).
enum LlmPrivacy { local, cloud }

/// One backend that can answer a chat request. Clients never construct
/// one; they read the active provider from the riverpod layer.
abstract interface class LlmProvider {
  /// Stable id: persisted in settings and written to the archive as
  /// `model.provider`. Lowercase, no spaces.
  String get id;

  /// What the status line and settings show, e.g.
  /// `openai-compatible @ http://192.168.1.20:8080`.
  String get displayName;

  LlmPrivacy get privacy;

  /// The model asked for when [LlmRequest.model] is null.
  String get defaultModel;

  /// Starts a streamed completion. Synchronous, and never throws:
  /// transport, protocol and backend errors arrive as the failure on
  /// [LlmCall.done]. Providers drive an [LlmCallController] and put
  /// their async work in [LlmCallController.run], which turns any
  /// throw or forgotten finish into a recorded failure.
  LlmCall start(LlmRequest request);

  /// Releases idle transport resources — pooled keep-alive sockets, say —
  /// promptly, keeping the provider open and usable: a running call is
  /// never disturbed, and the next call simply reconnects. Called when the
  /// selection moves away from this provider (#109); prompt release rides
  /// on the clients holding `connectionProvider` for the session, exactly
  /// like probing does. A provider holding nothing idle does nothing.
  void releaseIdle();

  /// Releases what the provider holds (an HTTP client, say). Calls still
  /// running are cancelled.
  Future<void> close();
}
