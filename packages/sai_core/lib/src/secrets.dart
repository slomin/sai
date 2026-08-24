/// Secret storage: the macOS Keychain through `Security.framework`
/// (ADR 0008), and an in-memory stand-in for tests and other platforms.
library;

export 'secrets/keychain.dart';
export 'secrets/secret_store.dart';
