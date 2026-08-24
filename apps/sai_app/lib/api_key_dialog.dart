import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'commands.dart';

/// The masked key field, for tests.
const apiKeyFieldKey = ValueKey('api-key-field');

/// The provider picker, for tests.
const apiKeyProviderKey = ValueKey('api-key-provider');

/// What the dialog says when no configured provider takes a key.
const noKeyedProviderText =
    'No configured provider takes an API key. Add one from the terminal: '
    'sai_tui provider add <id> --kind <kind> --key';

/// Enters or removes one provider's API key. The key goes straight to the
/// secret store (the Keychain, ADR 0008) and nowhere else: not into
/// settings, not into provider state, not into the archive. The full
/// settings screen is #40; this is the one thing the app must be able
/// to do before that.
class ApiKeyDialog extends ConsumerStatefulWidget {
  const ApiKeyDialog({super.key});

  @override
  ConsumerState<ApiKeyDialog> createState() => _ApiKeyDialogState();
}

class _ApiKeyDialogState extends ConsumerState<ApiKeyDialog> {
  final _controller = TextEditingController();
  String? _selected;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final keyed = [
      for (final p in settings.providers)
        if (p.credential != null) p,
    ];
    if (keyed.isEmpty) {
      return AlertDialog(
        title: const Text('Provider API Key'),
        content: const Text(noKeyedProviderText),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    }
    final id =
        _selected ??
        (keyed.any((p) => p.id == settings.llm)
            ? settings.llm!
            : keyed.first.id);
    final status = ref.watch(credentialStatusProvider(id));
    final statusText = switch (status) {
      CredentialStatus.set => 'A key is stored in the Keychain.',
      CredentialStatus.missing => 'No key stored yet.',
      CredentialStatus.unavailable => 'The Keychain could not be read.',
      CredentialStatus.none => '',
    };
    return AlertDialog(
      title: const Text('Provider API Key'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: apiKeyProviderKey,
            initialValue: id,
            decoration: const InputDecoration(labelText: 'Provider'),
            items: [
              for (final p in keyed)
                DropdownMenuItem(value: p.id, child: Text(p.id)),
            ],
            onChanged: (value) => setState(() {
              _selected = value;
              _controller.clear();
            }),
          ),
          const SizedBox(height: 12),
          Text(statusText),
          const SizedBox(height: 12),
          ValueListenableBuilder(
            valueListenable: _controller,
            builder: (context, value, _) => TextField(
              key: apiKeyFieldKey,
              controller: _controller,
              autofocus: true,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'API key'),
              onSubmitted: (_) => _save(id),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: status == CredentialStatus.set ? () => _remove(id) : null,
          child: const Text('Remove'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ValueListenableBuilder(
          valueListenable: _controller,
          builder: (context, value, _) => FilledButton(
            onPressed: value.text.trim().isEmpty ? null : () => _save(id),
            child: const Text('Save'),
          ),
        ),
      ],
    );
  }

  void _save(String id) {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    _commit(
      id,
      (credentials) => credentials.set(id, value),
      'key for $id saved',
    );
    _controller.clear();
  }

  void _remove(String id) => _commit(
    id,
    (credentials) => credentials.clear(id),
    'key for $id removed',
  );

  /// Runs [change] and closes; a refusal from the store goes to the
  /// status bar, without the value.
  void _commit(
    String id,
    void Function(CredentialsNotifier) change,
    String done,
  ) {
    final notice = ref.read(noticeProvider.notifier);
    try {
      change(ref.read(credentialsProvider.notifier));
      notice.show(done);
    } on SecretStoreException catch (e) {
      notice.show('the Keychain refused: ${e.message}');
    } on StateError catch (e) {
      notice.show(e.message);
    }
    Navigator.of(context).pop();
  }
}
