import 'dart:collection';
import 'dart:convert';

import '../llm/provider.dart';
import 'endpoint.dart';
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
    String? credentialOrigin,
    this.privacy,
    this.routing,
    Map<String, Object?> extra = const {},
  }) : extra = Map.unmodifiable(extra),
       credentialOrigin = _boundOrigin(endpoint, credential, credentialOrigin) {
    if (!idForm.hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'must match ${idForm.pattern}');
    }
    if (id == reservedNone) {
      throw ArgumentError.value(id, 'id', 'is reserved for "no provider"');
    }
    if (kind.isEmpty) throw ArgumentError('kind must not be empty');
    final e = endpoint;
    if (e != null) checkEndpoint(e);
    if (defaultModel != null && defaultModel!.isEmpty) {
      throw ArgumentError('default_model, when given, must not be empty');
    }
    if (routing != null && routing!.isEmpty) {
      throw ArgumentError('routing, when given, must not be empty');
    }
    final c = credential;
    if (c != null && !credentialForm.hasMatch(c)) {
      throw ArgumentError.value(
        c,
        'credential',
        'must match ${credentialForm.pattern}',
      );
    }
    // The same guard the reader applies, so nothing written here is ever
    // refused on the way back in (a value must not merely look like a key).
    try {
      rejectSecretLike(toJson(), where: 'provider $id');
    } on SettingsFormatException catch (e) {
      throw ArgumentError(e.reason);
    }
  }

  /// `none` is what `provider use none` means; no provider may take it.
  static const reservedNone = 'none';

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

  /// The origin (`scheme://host[:port]`) the key under [credential] was
  /// entered for, recorded when it was stored. The key is sent only while
  /// this equals the endpoint's origin (ADR 0009): after the endpoint moves
  /// it is not, until the key is entered again. Normalised on the way in:
  /// an origin that does not match the endpoint, or names no credential,
  /// is simply not a binding (null) — never a reason to refuse a file.
  final String? credentialOrigin;

  static String? _boundOrigin(
    String? endpoint,
    String? credential,
    String? origin,
  ) {
    if (origin == null || credential == null || endpoint == null) return null;
    final uri = Uri.tryParse(endpoint);
    if (uri == null) return null;
    return origin == endpointOrigin(uri) ? origin : null;
  }

  /// The privacy tag, when the configuration states one (#27): where the
  /// inference happens, `local` or `cloud`. Null leaves it to the kind —
  /// the fake is local, an `openai_compatible` endpoint follows its host
  /// (`defaultPrivacyFor`). A value this sai does not know is read as
  /// null, never as a reason to refuse a file (a newer sai may write a
  /// third tag); it is dropped on the next write.
  final LlmPrivacy? privacy;

  /// How a kind that routes inside a broker picks the endpoint (#24):
  /// for `openrouter`, `deepinfra_fp8` (the pinned preset) or `exact`
  /// (one model, the broker's own endpoint choice). Null for kinds with
  /// no routing; a word the kind does not know leaves the provider
  /// misconfigured, never silently re-routed. Stored as written.
  final String? routing;

  /// Keys this sai does not know, exactly as read.
  final Map<String, Object?> extra;

  /// The endpoint's origin, or null without an endpoint.
  String? get origin {
    final e = endpoint;
    return e == null ? null : endpointOrigin(Uri.parse(e));
  }

  /// Whether the stored key may be sent to [endpoint]: it takes one, and
  /// the one on record was entered for this origin.
  bool get keyBound => credential != null && credentialOrigin == origin;

  /// Throws [ArgumentError] unless [url] is an absolute http(s) URL with
  /// no userinfo, query or fragment — the places a key leaks into a URL.
  /// What a stored file must satisfy; [checkEndpointForEntry] adds the
  /// rule a new entry must, so that a rule tightened later never makes an
  /// existing file unreadable (the transport refuses at request time).
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

  /// [checkEndpoint] plus the entry-time rules: plaintext `http` only on
  /// this machine or the LAN (ADR 0009, 0012). Writers (the CLI, the
  /// dialogs) call this before storing; the reader does not.
  static void checkEndpointForEntry(String url) {
    checkEndpoint(url);
    final uri = Uri.parse(url);
    if (uri.scheme == 'http' && !isPrivateHost(uri.host)) {
      throw ArgumentError(plaintextRefused);
    }
  }

  /// A copy with the given fields replaced. The key binding follows the
  /// rule above: an origin that no longer matches the (new) endpoint, or
  /// a credential that is gone, drops it.
  ProviderConfig copyWith({
    String? kind,
    String? Function()? endpoint,
    String? Function()? defaultModel,
    String? Function()? credential,
    String? Function()? credentialOrigin,
    LlmPrivacy? Function()? privacy,
    String? Function()? routing,
  }) => ProviderConfig(
    id: id,
    kind: kind ?? this.kind,
    endpoint: endpoint == null ? this.endpoint : endpoint(),
    defaultModel: defaultModel == null ? this.defaultModel : defaultModel(),
    credential: credential == null ? this.credential : credential(),
    credentialOrigin: credentialOrigin == null
        ? this.credentialOrigin
        : credentialOrigin(),
    privacy: privacy == null ? this.privacy : privacy(),
    routing: routing == null ? this.routing : routing(),
    extra: extra,
  );

  /// A copy whose binding is dropped, for the cache key that must not
  /// change when a key is stored (`installedLlmsProvider`).
  ProviderConfig get unbound => copyWith(credentialOrigin: () => null);

  static const _known = {
    'id',
    'kind',
    'endpoint',
    'default_model',
    'credential',
    'credential_origin',
    'privacy',
    'routing',
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
    final privacyName = optional('privacy');
    final privacy = privacyName == null
        ? null
        : LlmPrivacy.values.asNameMap()[privacyName];
    try {
      return ProviderConfig(
        id: id,
        kind: kind,
        endpoint: optional('endpoint'),
        defaultModel: optional('default_model'),
        credential: optional('credential'),
        credentialOrigin: optional('credential_origin'),
        privacy: privacy,
        routing: optional('routing'),
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
    if (credentialOrigin != null) 'credential_origin': credentialOrigin,
    if (privacy != null) 'privacy': privacy!.name,
    if (routing != null) 'routing': routing,
  });

  /// Value equality over the stored form: two configs that would write
  /// the same JSON are the same config.
  @override
  bool operator ==(Object other) =>
      other is ProviderConfig &&
      jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;

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
