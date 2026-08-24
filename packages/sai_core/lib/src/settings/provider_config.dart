import 'dart:collection';

import 'settings.dart';

/// One configured LLM backend, as stored in `settings.json`
/// (`docs/settings/settings-v0.md`). Non-secret by construction: the
/// credential is an account *name* in the secret store, never a value.
final class ProviderConfig {
  ProviderConfig({
    required this.id,
    required this.kind,
    this.endpoint,
    this.defaultModel,
    this.credential,
    Map<String, Object?> extra = const {},
  }) : extra = Map.unmodifiable(extra) {
    if (!idForm.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'must match ${idForm.pattern}');
    }
    if (kind.isEmpty) throw ArgumentError('kind must not be empty');
    final e = endpoint;
    if (e != null) checkEndpoint(e);
    if (defaultModel != null && defaultModel!.isEmpty) {
      throw ArgumentError('default_model, when given, must not be empty');
    }
    final c = credential;
    if (c != null && !credentialForm.hasMatch(c)) {
      throw ArgumentError.value(
        c,
        'credential',
        'must match ${credentialForm.pattern}',
      );
    }
  }

  /// Lowercase, starts alphanumeric: the id is a file-safe, shell-safe
  /// name that `settings.llm` and the archive's `model.provider` carry.
  static final idForm = RegExp(r'^[a-z0-9][a-z0-9_-]*$');

  /// A credential names a secret-store account for a provider.
  static final credentialForm = RegExp(r'^provider:[a-z0-9][a-z0-9_-]*$');

  /// The account a provider's credential is filed under by convention.
  static String credentialFor(String id) => 'provider:$id';

  /// Persisted in `settings.llm` and written to the archive.
  final String id;

  /// Which implementation builds it: `fake`, `openai_compatible` (#22).
  /// Open, so a newer binary's kinds survive an older one's write.
  final String kind;

  /// Absolute `http`/`https` origin-plus-path, without userinfo, query or
  /// fragment. Null for kinds that have none.
  final String? endpoint;

  /// The model asked for when a request names none.
  final String? defaultModel;

  /// Secret-store account holding this provider's key; null when the
  /// backend takes none (a keyless `llama-server`, the fake).
  final String? credential;

  /// Keys this sai does not know, exactly as read.
  final Map<String, Object?> extra;

  /// Throws [ArgumentError] unless [url] is an absolute http(s) URL with
  /// no userinfo, query or fragment — the places a key leaks into a URL.
  static void checkEndpoint(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.isAbsolute ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw ArgumentError('endpoint must be an absolute http(s) URL');
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw ArgumentError('endpoint must carry no userinfo, query or fragment');
    }
  }

  ProviderConfig copyWith({
    String? kind,
    String? Function()? endpoint,
    String? Function()? defaultModel,
    String? Function()? credential,
  }) => ProviderConfig(
    id: id,
    kind: kind ?? this.kind,
    endpoint: endpoint == null ? this.endpoint : endpoint(),
    defaultModel: defaultModel == null ? this.defaultModel : defaultModel(),
    credential: credential == null ? this.credential : credential(),
    extra: extra,
  );

  static const _known = {
    'id',
    'kind',
    'endpoint',
    'default_model',
    'credential',
  };

  /// Reads one `providers[]` entry. Throws [SettingsFormatException] on a
  /// wrong shape, a bad value, or anything that looks like a secret.
  static ProviderConfig fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const SettingsFormatException('a provider must be an object');
    }
    rejectSecretLike(json, where: 'a provider');
    String? optional(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is! String || v.isEmpty) {
        throw SettingsFormatException(
          'provider $key must be a non-empty string',
        );
      }
      return v;
    }

    final id = optional('id');
    final kind = optional('kind');
    if (id == null || kind == null) {
      throw const SettingsFormatException('a provider needs id and kind');
    }
    try {
      return ProviderConfig(
        id: id,
        kind: kind,
        endpoint: optional('endpoint'),
        defaultModel: optional('default_model'),
        credential: optional('credential'),
        extra: {
          for (final e in json.entries)
            if (!_known.contains(e.key)) e.key: e.value,
        },
      );
    } on ArgumentError catch (e) {
      throw SettingsFormatException('provider $id: ${e.message}');
    }
  }

  Map<String, Object?> toJson() => SplayTreeMap<String, Object?>.of({
    ...extra,
    'id': id,
    'kind': kind,
    if (endpoint != null) 'endpoint': endpoint,
    if (defaultModel != null) 'default_model': defaultModel,
    if (credential != null) 'credential': credential,
  });

  @override
  String toString() =>
      'ProviderConfig($id, $kind'
      '${endpoint == null ? '' : ', $endpoint'}'
      '${credential == null ? '' : ', credential'})';
}

/// Key names that would mean a secret was written where none belongs.
const secretLikeKeys = {
  'api_key',
  'apikey',
  'key',
  'token',
  'secret',
  'password',
  'authorization',
};

/// Prefixes of values that are keys, not names.
final secretLikeValue = RegExp(r'^(sk-|Bearer\s)', caseSensitive: false);

/// Throws [SettingsFormatException] — naming the key, never the value —
/// when [object] holds a secret-looking key or a secret-looking string,
/// at any depth. The file is quarantined rather than read: a key on disk
/// is a leak, and refusing it is the loudest thing a reader can do.
void rejectSecretLike(Map<String, Object?> object, {required String where}) {
  void visit(Object? value, String path) {
    if (value is Map<String, Object?>) {
      for (final e in value.entries) {
        if (secretLikeKeys.contains(e.key.toLowerCase())) {
          throw SettingsFormatException(
            '$where holds a secret-like key "$path${e.key}"; '
            'secrets belong in the Keychain',
          );
        }
        visit(e.value, '$path${e.key}.');
      }
    } else if (value is List) {
      for (var i = 0; i < value.length; i++) {
        visit(value[i], '$path$i.');
      }
    } else if (value is String && secretLikeValue.hasMatch(value)) {
      throw SettingsFormatException(
        '$where holds a secret-like value under "$path"; '
        'secrets belong in the Keychain',
      );
    }
  }

  visit(object, '');
}
