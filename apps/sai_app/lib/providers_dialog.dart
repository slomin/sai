import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'commands.dart';

/// The masked key field, for tests.
const apiKeyFieldKey = ValueKey('api-key-field');

/// The streamed text of the endpoint test, for tests.
const providerTestOutputKey = ValueKey('provider-test-output');

/// One provider's row, for tests.
Key providerRowKey(String id) => ValueKey('provider-row-$id');

/// The focused provider surface before the settings screen (#40): every
/// provider this build can offer, the active one switched in one click,
/// an endpoint's health, models and context refreshed on demand, a
/// recorded streaming test, and the masked key field for a provider that
/// takes one. Keys go straight to the secret store (ADR 0008): never
/// settings, never provider state, never the archive.
class ProvidersDialog extends ConsumerStatefulWidget {
  const ProvidersDialog({super.key});

  @override
  ConsumerState<ProvidersDialog> createState() => _ProvidersDialogState();
}

class _ProvidersDialogState extends ConsumerState<ProvidersDialog> {
  final _controller = TextEditingController();
  String? _selected;

  RecordedCall? _test;
  String _testText = '';
  LlmResult? _testResult;
  StreamSubscription<LlmDelta>? _testDeltas;

  @override
  void dispose() {
    _testDeltas?.cancel();
    _controller.dispose();
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
    return AlertDialog(
      title: const Text('Providers'),
      content: SizedBox(
        width: 560,
        child: Column(
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
            const Divider(),
            if (config?.endpoint != null && provider != null)
              _endpoint(selected, provider),
            if (config?.credential != null) _key(selected),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
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
    final key = switch (status) {
      CredentialStatus.none => '',
      CredentialStatus.set =>
        config != null && config.endpoint != null && !config.keyBound
            ? ' · key needs re-entry'
            : ' · key set',
      CredentialStatus.missing => ' · no key',
      CredentialStatus.unavailable => ' · keychain unavailable',
    };
    final subtitle = provider == null
        ? (missing == null
              ? "kind '${config?.kind}' is not available in this build"
              : 'missing its $missing')
        : '${provider.defaultModel} — ${provider.privacy.name}$key';
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
    final running = _test != null && _testResult == null;
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
                    onPressed: () => _test?.cancel(),
                    child: const Text('Cancel test'),
                  )
                : TextButton(
                    onPressed: () => _runTest(provider),
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
    if (failure != null) {
      return 'failed: ${failure.kind.name} — ${failure.message}'
          '${failure.endpoint == null ? '' : ' (${failure.endpoint})'}';
    }
    final tps = result.usage?.tokensPerSecond;
    return '${result.finish.name}'
        '${tps == null ? ' · tokens/s unavailable' : ' · ${tps.toStringAsFixed(1)} tokens/s'}';
  }

  Widget _key(String id) {
    final status = ref.watch(credentialStatusProvider(id));
    final config = ref.watch(settingsProvider).provider(id);
    final statusText = switch (status) {
      CredentialStatus.set =>
        config != null && config.endpoint != null && !config.keyBound
            ? 'A key is stored, but for another endpoint: enter it again.'
            : 'A key is stored in the Keychain.',
      CredentialStatus.missing => 'No key stored yet.',
      CredentialStatus.unavailable => 'The Keychain could not be read.',
      CredentialStatus.none => '',
    };
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
                onPressed: value.text.trim().isEmpty ? null : () => _save(id),
                child: const Text('Save'),
              ),
            ],
          ),
        ),
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
    notice.show(ref.read(llmStatusProvider));
  }

  void _resetTest() {
    _testDeltas?.cancel();
    _testDeltas = null;
    _test = null;
    _testText = '';
    _testResult = null;
  }

  Future<void> _runTest(LlmProvider provider) async {
    setState(_resetTest);
    final RecordedCall call;
    try {
      final recorder = await ref.read(llmRecorderProvider.future);
      call = await recorder.start(provider, providerTestRequest());
    } on Object catch (error) {
      if (!mounted) return;
      ref.read(noticeProvider.notifier).show('test failed to start: $error');
      return;
    }
    if (!mounted) return call.cancel();
    setState(() => _test = call);
    _testDeltas = call.deltas.listen((_) {
      if (mounted) setState(() => _testText = call.text);
    });
    final result = await call.done;
    if (!mounted) return;
    setState(() {
      _testText = result.text;
      _testResult = result;
    });
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
