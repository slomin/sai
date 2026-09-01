import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../commands.dart';
import 'settings_row.dart';

/// The masked key field, for tests.
const apiKeyFieldKey = ValueKey('api-key-field');

/// The streamed text of the endpoint test, for tests.
const providerTestOutputKey = ValueKey('provider-test-output');

/// The cloud-sharing switch (#27), for tests.
const shareTasksSwitchKey = ValueKey('share-tasks-switch');

/// The reasoning switch (#34), for tests.
const reasoningSwitchKey = ValueKey('reasoning-switch');

/// One provider's row, for tests.
Key providerRowKey(String id) => ValueKey('provider-row-$id');

/// The OpenRouter model block (#24), for tests: the recommended preset,
/// the exact-model row, its id field and the button that applies it.
const openRouterPresetKey = ValueKey('openrouter-preset');
const openRouterExactKey = ValueKey('openrouter-exact');
const openRouterModelFieldKey = ValueKey('openrouter-model-field');
const openRouterApplyKey = ValueKey('openrouter-apply');

/// Settings › Providers (#40, the dialog of #29 as a page): every
/// provider this build can offer, the active one switched in one click,
/// an endpoint's health, models and context refreshed on demand, a
/// recorded streaming test, and the masked key field for a provider that
/// takes one. Keys go straight to the secret store (ADR 0008): never
/// settings, never provider state, never the archive. OpenRouter (#24)
/// adds its model block: the recommended pinned preset or one exact id.
class ProvidersPage extends ConsumerStatefulWidget {
  const ProvidersPage({super.key});

  @override
  ConsumerState<ProvidersPage> createState() => _ProvidersPageState();
}

class _ProvidersPageState extends ConsumerState<ProvidersPage> {
  final _controller = TextEditingController();
  final _model = TextEditingController();
  String? _selected;

  RecordedCall? _test;
  String _testText = '';
  LlmResult? _testResult;
  StreamSubscription<LlmDelta>? _testDeltas;

  /// Which test the screen belongs to; a result from an older one is
  /// dropped. [_starting] holds a second click while one is starting.
  var _generation = 0;
  var _starting = false;

  @override
  void dispose() {
    _resetTest();
    _controller.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final registry = ref.watch(llmRegistryProvider);
    final misconfigured = ref.watch(misconfiguredLlmsProvider);
    final ids = [
      ...registry.keys,
      for (final p in settings.providers)
        if (!registry.containsKey(p.id)) p.id,
    ];
    final selected = ids.contains(_selected)
        ? _selected!
        : ids.contains(settings.llm)
        ? settings.llm!
        : ids.first;
    final config = settings.provider(selected);
    final provider = registry[selected];
    // OpenRouter's block shows for the built provider and for an entry of
    // that kind the factory refused: the block is how it is repaired.
    final openRouter =
        (provider != null && openRouterRoutingOf(provider) != null) ||
        config?.kind == openRouterKind;
    final routing = provider == null
        ? OpenRouterRouting.parse(config?.routing)
        : openRouterRoutingOf(provider);
    // A configured entry names its account; an unconfigured built-in that
    // ships taking a key (OpenRouter) says so itself.
    final takesKey =
        config?.credential != null ||
        (provider is OpenAiCompatibleProvider && provider.takesKey);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsPageHeader(
          eyebrow: 'Providers',
          title: 'Where the answers come from',
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final id in ids)
              _row(
                id,
                config: settings.provider(id),
                provider: registry[id],
                missing: misconfigured[id],
                active: settings.llm == id,
                selected: selected == id,
              ),
            SwitchListTile(
              key: shareTasksSwitchKey,
              dense: true,
              title: const Text('Allow cloud providers to see my tasks'),
              subtitle: Text(
                settings.shareTasksWithCloud
                    ? 'A cloud provider sees the task list with each request.'
                    : 'Cloud providers answer without the task list.',
              ),
              value: settings.shareTasksWithCloud,
              onChanged: _setShareTasks,
            ),
            SwitchListTile(
              key: reasoningSwitchKey,
              dense: true,
              title: const Text('Let the model think before it answers'),
              subtitle: Text(
                settings.reasoningOn
                    ? 'The chat shows the thinking above the answer.'
                    : 'The model answers directly (faster).',
              ),
              value: settings.reasoningOn,
              onChanged: _setReasoning,
            ),
            const Divider(),
            // Any endpoint that can be asked, a built-in's included (#23).
            if (provider != null &&
                (config?.endpoint != null || provider is LlmEndpointProbe))
              _endpoint(selected, provider),
            if (openRouter)
              _openRouterModel(
                selected,
                provider,
                config,
                routing,
                model: config?.defaultModel ?? provider?.defaultModel,
              ),
            if (takesKey) _key(selected, revokeElsewhere: openRouter),
          ],
        ),
      ],
    );
  }

  Widget _row(
    String id, {
    required ProviderConfig? config,
    required LlmProvider? provider,
    required String? missing,
    required bool active,
    required bool selected,
  }) {
    final status = ref.watch(credentialStatusProvider(id));
    final key = credentialSuffix(status, config);
    final routing = switch (provider == null
        ? null
        : openRouterRoutingOf(provider)) {
      final r? => ' · ${r.label}',
      null => '',
    };
    final subtitle = provider == null
        ? (missing == null
              ? "kind '${config?.kind}' is not available in this build"
              : misconfiguredNote(missing))
        : '${provider.defaultModel} — ${provider.privacy.name}$routing$key';
    return ListTile(
      key: providerRowKey(id),
      dense: true,
      selected: selected,
      leading: Icon(active ? Icons.check : null, size: 18),
      title: Text(provider?.displayName ?? id),
      subtitle: Text(subtitle),
      trailing: TextButton(
        onPressed: provider == null || active ? null : () => _use(id),
        child: const Text('Use'),
      ),
      onTap: () => setState(() {
        _selected = id;
        _controller.clear();
        _model.clear();
        _resetTest();
      }),
    );
  }

  Widget _endpoint(String id, LlmProvider provider) {
    final info = ref.watch(endpointInfoProvider(id));
    final line = switch (info) {
      AsyncData(:final value) => _describe(value),
      AsyncError() => 'could not be asked',
      _ => 'asking…',
    };
    final running = _starting || (_test != null && _testResult == null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(line, maxLines: 2)),
            TextButton(
              onPressed: info.isLoading
                  ? null
                  : () => ref.invalidate(endpointInfoProvider(id)),
              child: const Text('Refresh'),
            ),
            running
                ? TextButton(
                    onPressed: _test == null ? null : () => _test?.cancel(),
                    child: const Text('Cancel test'),
                  )
                : TextButton(
                    // A dev copy cannot send a key it does not hold.
                    onPressed:
                        ref.watch(credentialStatusProvider(provider.id)) ==
                            CredentialStatus.absent
                        ? null
                        : () => _runTest(provider),
                    child: const Text('Test'),
                  ),
          ],
        ),
        if (_test != null) ...[
          const SizedBox(height: 8),
          Container(
            key: providerTestOutputKey,
            constraints: const BoxConstraints(maxHeight: 120),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(4),
            ),
            child: SingleChildScrollView(
              child: Text(_testText.isEmpty ? '…' : _testText),
            ),
          ),
          const SizedBox(height: 4),
          Text(_testResult == null ? 'testing…' : _outcome(_testResult!)),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  static String _describe(EndpointInfo info) {
    final failure = info.failure;
    if (failure != null) return 'unavailable: ${failure.message}';
    final models = info.models.isEmpty
        ? 'no models listed'
        : '${info.models.length} model${info.models.length == 1 ? '' : 's'}';
    return [
      info.health.name,
      if (info.serverKind != null) info.serverKind!,
      models,
      info.contextWindow == null
          ? 'context unavailable'
          : 'context ${info.contextWindow}',
    ].join(' · ');
  }

  static String _outcome(LlmResult result) {
    final failure = result.failure;
    if (failure != null) return chatFailureLine(failure);
    final tps = result.usage?.tokensPerSecond;
    return '${result.finish.name}'
        '${tps == null ? ' · tokens/s unavailable' : ' · ${tps.toStringAsFixed(1)} tokens/s'}';
  }

  /// OpenRouter's model (#24): the recommended preset — one model pinned
  /// to one host and quantization, no fallback — or one exact id of the
  /// person's own. Either writes the entry (configuring the built-in as
  /// shipped first, or repairing an entry the factory refused); the
  /// routing is stored, never inferred from the id. [routing] is null
  /// for an entry whose word this sai does not know: neither row is
  /// checked, and either tap writes a good one.
  Widget _openRouterModel(
    String id,
    LlmProvider? provider,
    ProviderConfig? config,
    OpenRouterRouting? routing, {
    required String? model,
  }) {
    final exact = routing == OpenRouterRouting.exact;
    final preset = routing == OpenRouterRouting.deepinfraFp8;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: openRouterPresetKey,
          dense: true,
          selected: preset,
          leading: Icon(preset ? Icons.check : null, size: 18),
          title: const Text('Recommended: $openRouterPresetModel'),
          subtitle: const Text(
            'Pinned to DeepInfra, FP8, no fallback; data collection denied, '
            'zero retention required.',
          ),
          onTap: preset
              ? null
              : () => _route(
                  id,
                  provider,
                  config,
                  OpenRouterRouting.deepinfraFp8,
                  openRouterPresetModel,
                ),
        ),
        ListTile(
          key: openRouterExactKey,
          dense: true,
          selected: exact,
          leading: Icon(exact ? Icons.check : null, size: 18),
          title: const Text('Exact model'),
          subtitle: Text(
            exact
                ? '$model — OpenRouter picks among that '
                      "model's endpoints, never another model; the same "
                      'privacy filters apply.'
                : 'One owner/name id from openrouter.ai/models; the same '
                      'privacy filters apply, and never another model.',
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ValueListenableBuilder(
            valueListenable: _model,
            builder: (context, value, _) => Row(
              children: [
                Expanded(
                  child: TextField(
                    key: openRouterModelFieldKey,
                    controller: _model,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Model id',
                      hintText: 'owner/name',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _applyModel(id, provider, config),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: openRouterApplyKey,
                  onPressed: value.text.trim().isEmpty
                      ? null
                      : () => _applyModel(id, provider, config),
                  child: const Text('Apply'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  void _applyModel(String id, LlmProvider? provider, ProviderConfig? config) {
    final model = _model.text.trim();
    if (model.isEmpty) return;
    final problem = openRouterModelProblem(model);
    if (problem != null) {
      ref.read(noticeProvider.notifier).show(problem);
      return;
    }
    _route(id, provider, config, OpenRouterRouting.exact, model);
  }

  void _route(
    String id,
    LlmProvider? provider,
    ProviderConfig? config,
    OpenRouterRouting routing,
    String model,
  ) {
    final notice = ref.read(noticeProvider.notifier);
    final base = config ?? (provider == null ? null : configFor(provider));
    if (base == null) return;
    try {
      // The whole shape the kind wants, so an entry that came in wrong
      // (an endpoint, a local tag) leaves right.
      ref
          .read(settingsProvider.notifier)
          .upsertProvider(
            base.copyWith(
              kind: openRouterKind,
              endpoint: () => null,
              privacy: () => LlmPrivacy.cloud,
              credential: () =>
                  base.credential ?? ProviderConfig.credentialFor(id),
              defaultModel: () => model,
              routing: () => routing.word,
            ),
          );
    } on ArgumentError catch (e) {
      notice.show('${e.message}');
      return;
    } on StateError catch (e) {
      notice.show(e.message);
      return;
    }
    _model.clear();
    notice.show('$id: $model · ${routing.label}');
  }

  Widget _key(String id, {required bool revokeElsewhere}) {
    final status = ref.watch(credentialStatusProvider(id));
    final config = ref.watch(settingsProvider).provider(id);
    final statusText = switch (status) {
      // An origin that never moves has no "other endpoint" to speak of.
      CredentialStatus.set =>
        !revokeElsewhere &&
                config != null &&
                config.endpoint != null &&
                !config.keyBound
            ? 'A key is stored, but for another endpoint: enter it again.'
            : 'A key is stored in the Keychain.',
      CredentialStatus.missing => 'No key stored yet.',
      CredentialStatus.unavailable => 'The Keychain could not be read.',
      // Dev holds no credentials (#95, ADR 0019).
      CredentialStatus.absent =>
        'The dev copy holds no credentials. Use the stable app for this '
            'provider.',
      CredentialStatus.none => '',
    };
    final absent = status == CredentialStatus.absent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(statusText),
        const SizedBox(height: 8),
        ValueListenableBuilder(
          valueListenable: _controller,
          builder: (context, value, _) => Row(
            children: [
              Expanded(
                child: TextField(
                  key: apiKeyFieldKey,
                  controller: _controller,
                  enabled: !absent,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'API key',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _save(id),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: status == CredentialStatus.set
                    ? () => _remove(id)
                    : null,
                child: const Text('Remove'),
              ),
              FilledButton(
                onPressed: absent || value.text.trim().isEmpty
                    ? null
                    : () => _save(id),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
        if (revokeElsewhere) ...[
          const SizedBox(height: 4),
          const Text(
            'Remove deletes the Keychain item only; revoke the key at '
            'openrouter.ai as well. Use a dedicated key with a spending cap.',
          ),
        ],
      ],
    );
  }

  void _use(String id) {
    final notice = ref.read(noticeProvider.notifier);
    try {
      ref.read(settingsProvider.notifier).selectLlm(id);
    } on StateError catch (e) {
      notice.show(e.message);
      return;
    }
    // The warning beats the status line: the bar already shows the line.
    notice.show(
      ref.read(activeLlmWarningProvider) ?? ref.read(llmStatusProvider),
    );
  }

  void _setReasoning(bool on) {
    final notice = ref.read(noticeProvider.notifier);
    try {
      ref.read(settingsProvider.notifier).setReasoning(on);
    } on StateError catch (e) {
      notice.show(e.message);
      return;
    }
    notice.show(on ? 'reasoning on' : 'reasoning off');
  }

  void _setShareTasks(bool share) {
    final notice = ref.read(noticeProvider.notifier);
    try {
      ref.read(settingsProvider.notifier).setShareTasksWithCloud(share);
    } on StateError catch (e) {
      notice.show(e.message);
      return;
    }
    notice.show(
      ref.read(activeLlmWarningProvider) ??
          (share ? 'cloud sharing on' : 'cloud sharing off'),
    );
  }

  /// Drops the current test: an abandoned call is cancelled, so it stops
  /// streaming and the recorder closes its record — not just forgotten.
  void _resetTest() {
    _generation++;
    _testDeltas?.cancel();
    _testDeltas = null;
    _test?.cancel();
    _test = null;
    _testText = '';
    _testResult = null;
    _starting = false;
  }

  Future<void> _runTest(LlmProvider provider) async {
    if (_starting) return;
    setState(() {
      _resetTest();
      _starting = true;
    });
    final generation = _generation;
    bool current() => mounted && generation == _generation;
    final RecordedCall call;
    try {
      final recorder = await ref.read(llmRecorderProvider.future);
      call = await recorder.start(
        provider,
        providerTestRequest(
          reasoning: ref.read(reasoningProvider) ? null : false,
        ),
      );
    } on Object catch (error) {
      if (!current()) return;
      setState(() => _starting = false);
      ref.read(noticeProvider.notifier).show('test failed to start: $error');
      return;
    }
    if (!current()) return call.cancel();
    setState(() {
      _test = call;
      _starting = false;
    });
    _testDeltas = call.deltas.listen((_) {
      if (current()) setState(() => _testText = call.text);
    });
    final result = await call.done;
    if (!current()) return;
    setState(() {
      _testText = result.text;
      _testResult = result;
    });
    // The test wrote its lines straight through the recorder: the archive
    // counts re-read, and the light learns of a failure now.
    ref.read(archiveRevisionProvider.notifier).bump();
    if (result.failure case final failure?) {
      ref.read(connectionProvider.notifier).callFailed(failure);
    }
  }

  void _save(String id) {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    if (_commit(
      id,
      (credentials) => credentials.set(id, value),
      'key for $id saved',
    )) {
      _controller.clear();
    }
  }

  void _remove(String id) => _commit(
    id,
    (credentials) => credentials.clear(id),
    'key for $id removed',
  );

  /// Runs [change]. A refusal goes to the status bar, without the value,
  /// and what was typed stays so the user can retry rather than retype.
  bool _commit(
    String id,
    void Function(CredentialsNotifier) change,
    String done,
  ) {
    final notice = ref.read(noticeProvider.notifier);
    try {
      change(ref.read(credentialsProvider.notifier));
    } on SecretStoreException catch (e) {
      notice.show('the Keychain refused: ${e.message}');
      return false;
    } on StateError catch (e) {
      notice.show(e.message);
      return false;
    }
    notice.show(done);
    return true;
  }
}
