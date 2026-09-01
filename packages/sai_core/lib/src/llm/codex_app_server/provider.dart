import 'dart:async';

import '../../archive/event.dart';
import '../call.dart';
import '../effort.dart';
import '../failure.dart';
import '../probe.dart';
import '../provider.dart';
import 'config.dart';
import 'protocol.dart';
import 'runtime.dart';
import 'text.dart';

/// A ChatGPT plan through the Codex App Server (#26, ADR 0013). sai
/// holds no token: the runtime owns login, refresh and logout, and this
/// provider asks it, over stdio, for one thing — a streamed answer to
/// sai's governed messages, on the exact model and effort the person
/// chose. Before any prompt goes: the account must be a ChatGPT one, the
/// model must be in the live list and take the effort, and the request
/// must set no temperature (the runtime has no such field). Each call is
/// a fresh ephemeral thread in a scratch directory under a read-only
/// sandbox with approvals off; any act beyond answering ends the turn.
/// A failure here is never retried on the API key route, or anywhere.
final class ChatGptSubscriptionProvider
    implements LlmProvider, LlmEndpointProbe, ConfiguredEffort {
  ChatGptSubscriptionProvider({
    required this.id,
    required this.installedRuntime,
    String? defaultModel,
    this.reasoningEffort,
    this.noRuntimeText = CodexText.devRefused,
  }) : _model = defaultModel;

  @override
  final String id;

  /// The App Server child; shared by every entry of this kind in the
  /// process, since they share the one credential home. Null where none
  /// can run — the dev flavor (#95), a build without the sidecar — and
  /// every call then refuses in fixed words before any spawn.
  final AppServerRuntime? installedRuntime;

  /// Why there is no runtime, when there is none: the dev copy runs
  /// none, or the home named for it was refused.
  final String noRuntimeText;

  /// The runtime, or the fixed refusal.
  AppServerRuntime get runtime {
    final r = installedRuntime;
    if (r == null) throw CodexException(noRuntimeText, credential: true);
    return r;
  }

  /// Whether a runtime is there at all.
  bool get hasRuntime => installedRuntime != null;

  /// The exact model id the person chose, or null until they have.
  final String? _model;

  @override
  final ReasoningEffort? reasoningEffort;

  final _running = <LlmCallController>{};
  var _closed = false;

  /// Where the plan's models run: OpenAI's servers. Cloud, always.
  @override
  LlmPrivacy get privacy => LlmPrivacy.cloud;

  @override
  String get displayName => '$id @ ChatGPT';

  /// The settings `kind` a configuration of this provider carries.
  String get kind => chatGptKind;

  /// [CodexText.chooseModel] stands in while no model is chosen: a
  /// status line can show it, and every call refuses on it.
  @override
  String get defaultModel => _model ?? CodexText.chooseModel;

  /// Whether a model has been chosen at all.
  bool get hasModel => _model != null;

  /// The last model list read, for the pair check; refreshed per call.
  List<CodexModel>? _catalogue;

  @override
  LlmCall start(LlmRequest request) {
    final model = ModelRef(provider: id, id: request.model ?? defaultModel);
    final cancelled = Completer<void>();
    final controller = LlmCallController(
      model: model,
      onCancel: () {
        if (!cancelled.isCompleted) cancelled.complete();
      },
    );
    _running.add(controller);
    controller.call.done.whenComplete(() => _running.remove(controller));
    controller.run(() => _run(controller, request, cancelled.future));
    return controller.call;
  }

  Future<void> _run(
    LlmCallController controller,
    LlmRequest request,
    Future<void> cancelled,
  ) async {
    void fail(LlmFailureKind kind, String text) {
      if (controller.isDone) return;
      controller.finish(
        LlmResult(
          text: controller.text,
          finish: LlmFinish.failed,
          model: controller.model,
          usage: controller.usage,
          failure: LlmFailure(kind, text),
          reasoning: controller.reasoning,
        ),
      );
    }

    if (_closed) return fail(LlmFailureKind.internal, CodexText.closed);
    final model = request.model ?? _model;
    if (model == null) {
      return fail(LlmFailureKind.rejected, CodexText.chooseModel);
    }
    if (request.temperature != null) {
      return fail(LlmFailureKind.rejected, CodexText.temperatureUnsupported);
    }
    final effort = request.reasoningEffort;
    try {
      // The gates, before any prompt-bearing call: who is signed in, and
      // whether the pair the person chose is one the runtime lists now.
      final account = await runtime.account();
      if (controller.isDone) return;
      if (!account.isChatGpt) {
        return fail(
          LlmFailureKind.credential,
          account.type == CodexAccountType.none
              ? CodexText.signedOut
              : CodexText.wrongAuth,
        );
      }
      final models = await runtime.models();
      if (controller.isDone) return;
      _catalogue = models;
      final chosen = models.where((m) => m.id == model).firstOrNull;
      if (chosen == null) {
        return fail(LlmFailureKind.rejected, CodexText.modelUnavailable);
      }
      if (effort != null && !chosen.takes(effort)) {
        return fail(LlmFailureKind.rejected, CodexText.effortUnavailable);
      }
      final outcome = await runtime.turn(
        model: model,
        effort: effort,
        messages: request.messages,
        outputSchema: request.responseSchema?.schema,
        onText: (text) {
          if (!controller.isDone && text.isNotEmpty) controller.add(text);
        },
        onReasoning: (text) {
          if (!controller.isDone && text.isNotEmpty) {
            controller.addReasoning(text);
          }
        },
        cancelled: cancelled,
      );
      if (controller.isDone) return;
      if (outcome.usage != null) controller.usage = outcome.usage;
      final lineage = ModelRef(
        provider: id,
        id: model,
        version: outcome.model == model ? null : outcome.model,
        requestId: outcome.turnId,
      );
      if (outcome.unsafe) {
        return fail(LlmFailureKind.protocol, CodexText.unsafe);
      }
      if (outcome.protocolFailure case final why?) {
        return fail(LlmFailureKind.unreachable, why);
      }
      switch (outcome.status) {
        case CodexTurnStatus.completed:
          controller.finish(
            LlmResult(
              text: controller.text,
              reasoning: controller.reasoning,
              finish: LlmFinish.stop,
              model: lineage,
              usage: outcome.usage,
            ),
          );
        case CodexTurnStatus.interrupted:
          // Interrupted without sai asking: upstream's decision. What
          // came is kept, with the failure.
          fail(LlmFailureKind.rejected, CodexText.rejected);
        case CodexTurnStatus.failed:
        case CodexTurnStatus.inProgress:
        case CodexTurnStatus.unknown:
          switch (outcome.errorClass) {
            case CodexErrorClass.planLimit:
              fail(LlmFailureKind.rejected, CodexText.planLimit);
            case CodexErrorClass.unauthorized:
              fail(LlmFailureKind.credential, CodexText.unauthorized);
            case CodexErrorClass.overloaded:
              fail(LlmFailureKind.rejected, CodexText.overloaded);
            case CodexErrorClass.other:
              fail(LlmFailureKind.rejected, CodexText.errorPayload);
          }
      }
    } on CodexException catch (e) {
      fail(
        e.credential ? LlmFailureKind.credential : LlmFailureKind.unreachable,
        e.text,
      );
    }
  }

  /// The account read and the model list: `ok` with the ids when a
  /// ChatGPT account is signed in, or the failure that stands in the
  /// way — signed out, in use elsewhere, no runtime.
  @override
  Future<EndpointInfo> probe() async {
    try {
      final account = await runtime.account();
      if (!account.isChatGpt) {
        return EndpointInfo(
          health: EndpointHealth.unavailable,
          failure: LlmFailure(
            LlmFailureKind.credential,
            account.type == CodexAccountType.none
                ? CodexText.signedOut
                : CodexText.wrongAuth,
          ),
        );
      }
      final models = await runtime.models();
      _catalogue = models;
      return EndpointInfo(
        health: EndpointHealth.ok,
        models: [for (final m in models) m.id],
        serverKind: chatGptKind,
      );
    } on CodexException catch (e) {
      return EndpointInfo(
        health: EndpointHealth.unavailable,
        failure: LlmFailure(
          e.credential ? LlmFailureKind.credential : LlmFailureKind.unreachable,
          e.text,
        ),
      );
    }
  }

  /// The model list as last read by a call or a probe, for the clients'
  /// pair check without another round trip; null before any.
  List<CodexModel>? get lastCatalogue => _catalogue;

  /// The runtime's idle child is ended when this provider is switched
  /// away from; a login or a turn under way is left alone.
  @override
  void releaseIdle() {
    final r = installedRuntime;
    if (r != null) unawaited(r.releaseIdle());
  }

  /// Closes this provider; the runtime is shared and outlives it.
  @override
  Future<void> close() async {
    _closed = true;
    for (final controller in _running.toList()) {
      controller.cancel();
    }
  }
}
