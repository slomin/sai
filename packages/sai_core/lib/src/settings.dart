/// Non-secret settings: one JSON file beside the archive (ADR 0006), the
/// schema in `docs/settings/settings-v0.md`. Never a secret: keys live in
/// the Keychain (`secrets.dart`) and the file names their accounts.
library;

export 'settings/endpoint.dart';
export 'settings/provider_config.dart';
export 'settings/settings.dart';
export 'settings/store.dart';
export 'settings/workspace.dart';
