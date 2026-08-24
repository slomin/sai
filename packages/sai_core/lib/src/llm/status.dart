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
