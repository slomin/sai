/// A secret could not be read or written. Carries a fixed message and, on
/// macOS, the `OSStatus` — never the value that was being stored.
final class SecretStoreException implements Exception {
  const SecretStoreException(this.message, {this.status});

  final String message;

  /// The Security framework's `OSStatus`, where one applies.
  final int? status;

  @override
  String toString() =>
      'SecretStoreException: $message${status == null ? '' : ' ($status)'}';
}

/// Where secrets live: one item per [account], addressed by name, never
/// written to the settings file or the archive. The only path in sai that
/// touches a credential; everything else passes the account name around.
///
/// Synchronous, like `SettingsStore`: an item is a few dozen bytes and the
/// callers are notifiers.
abstract interface class SecretStore {
  /// The secret stored under [account], or null when there is none.
  String? read(String account);

  /// Whether [account] holds a secret, without reading it.
  bool has(String account);

  /// Stores [value] under [account], replacing in place what is there.
  /// Throws [ArgumentError] on an empty value or a malformed account.
  void write(String account, String value);

  /// Removes [account]. Returns whether there was one.
  bool delete(String account);
}

/// Account names are one line of printable text: `provider:<id>` today.
final accountForm = RegExp(r'^[\x21-\x7e]+$');

/// Throws [ArgumentError] when [account] is not a usable name. The value
/// is never part of the message.
void checkAccount(String account) {
  if (!accountForm.hasMatch(account)) {
    throw ArgumentError.value(account, 'account', 'not a printable name');
  }
}

/// Throws [ArgumentError] on an empty secret, without quoting it.
void checkValue(String value) {
  if (value.isEmpty) {
    throw ArgumentError('a secret must not be empty');
  }
}

/// A store that forgets on exit: tests, and any platform without a
/// Keychain. Never a place a real key should go.
final class InMemorySecretStore implements SecretStore {
  final _items = <String, String>{};

  /// The account names held, sorted — for assertions.
  List<String> get accounts => _items.keys.toList()..sort();

  @override
  String? read(String account) {
    checkAccount(account);
    return _items[account];
  }

  @override
  bool has(String account) {
    checkAccount(account);
    return _items.containsKey(account);
  }

  @override
  void write(String account, String value) {
    checkAccount(account);
    checkValue(value);
    _items[account] = value;
  }

  @override
  bool delete(String account) {
    checkAccount(account);
    return _items.remove(account) != null;
  }
}
