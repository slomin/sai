import 'provider.dart';

/// What the status line shows while no provider is selected.
const noProviderStatus = 'no provider — local only';

/// What it shows when the settings file could not be used (ADR 0006).
const unreadableSettingsStatus = 'settings unreadable — local only';

/// What it shows when the selected id is not in this build's registry.
String missingProviderStatus(String id) =>
    "provider '$id' is not available — local only";

/// The status line for a selected provider: name, default model, privacy
/// tag — the same in every client.
String llmStatusLine(LlmProvider provider) =>
    '${provider.displayName} (${provider.defaultModel}) — '
    '${provider.privacy.name}';

/// What it shows when the selected provider is configured but no
/// factory in this build knows its kind.
String unavailableKindStatus(String id, String kind) =>
    "provider '$id' has kind '$kind', which this sai cannot build — "
    'local only';

/// What it shows when the selected provider's kind is known but its
/// configuration lacks what the kind needs (an endpoint, a model).
String misconfiguredStatus(String id, String missing) =>
    "provider '$id' is missing its $missing — local only";

/// The one-line note both clients show beside a provider that lacks a
/// key its kind needs (see `llmKindNeeds`).
String misconfiguredNote(String missing) => 'missing its $missing';

/// Appended to the status line when the provider names a credential the
/// secret store does not hold.
const missingCredentialSuffix = ' · no key';

/// Appended when the key is there and bound to this endpoint.
const setCredentialSuffix = ' · key set';

/// Appended when the key is there but was entered for another endpoint.
const reenterCredentialSuffix = ' · key needs re-entry';

/// Appended when the secret store could not be asked.
const unavailableSecretsSuffix = ' · keychain unavailable';
