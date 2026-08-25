import 'dart:collection';
import 'dart:convert';

import 'provider_config.dart';

/// The file's content was not settings: not JSON, not an object, or a
/// known key with the wrong type. The store quarantines such a file.
final class SettingsFormatException implements Exception {
  const SettingsFormatException(this.reason);

  final String reason;

  @override
  String toString() => 'SettingsFormatException: $reason';
}

/// The file was written by a newer sai. Nothing here understands it, and
/// nothing here may overwrite it.
final class NewerSettingsVersion implements Exception {
  const NewerSettingsVersion(this.version);

  final int version;

  @override
  String toString() =>
      'NewerSettingsVersion: settings are version $version, '
      'this sai understands ${Settings.version}';
}

/// The settings value: the selected provider, the configured providers,
/// plus whatever a newer or later sai stored, carried verbatim so a write
/// never erases it. Never a secret (`docs/settings/settings-v0.md`).
final class Settings {
  const Settings({
    this.llm,
    this.providers = const [],
    this.shareTasksWithCloud = false,
    this.problem,
    this.extra = const {},
  });

  /// Nothing selected, nothing wrong.
  static const empty = Settings();

  /// The format this sai writes.
  static const version = 0;

  /// Id of the selected `LlmProvider`, or null for none.
  final String? llm;

  /// The configured providers, in file order; ids unique.
  final List<ProviderConfig> providers;

  /// The privacy switch (#27): whether a cloud-tagged provider may see the
  /// task list. Off by default; the recorder reads it before every call.
  final bool shareTasksWithCloud;

  /// The configured provider with [id], or null.
  ProviderConfig? provider(String id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Why the stored settings could not be used, when they could not be —
  /// shown to the user, never written.
  final String? problem;

  /// Keys this sai does not know, exactly as read.
  final Map<String, Object?> extra;

  /// The same settings with [id] selected. Clears [problem]: a write
  /// after a quarantine starts the file fresh.
  Settings withLlm(String? id) => Settings(
    llm: id,
    providers: providers,
    shareTasksWithCloud: shareTasksWithCloud,
    extra: extra,
  );

  /// The same settings with the cloud-sharing switch set. Clears
  /// [problem] like [withLlm].
  Settings withShareTasksWithCloud(bool share) => Settings(
    llm: llm,
    providers: providers,
    shareTasksWithCloud: share,
    extra: extra,
  );

  /// The same settings with [config] added, or replacing the provider
  /// with its id in place. Clears [problem] like [withLlm].
  Settings withProvider(ProviderConfig config) {
    final next = [
      for (final p in providers)
        if (p.id == config.id) config else p,
      if (provider(config.id) == null) config,
    ];
    return Settings(
      llm: llm,
      providers: next,
      shareTasksWithCloud: shareTasksWithCloud,
      extra: extra,
    );
  }

  /// The same settings without the provider [id]; a selection of it is
  /// cleared too, so `llm` never names a provider that is gone.
  Settings withoutProvider(String id) => Settings(
    llm: llm == id ? null : llm,
    providers: [
      for (final p in providers)
        if (p.id != id) p,
    ],
    shareTasksWithCloud: shareTasksWithCloud,
    extra: extra,
  );

  /// Parses the file's text. Throws [SettingsFormatException] on anything
  /// that is not a v0 settings object and [NewerSettingsVersion] on a
  /// version this sai does not understand.
  static Settings decode(String text) {
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (e) {
      throw SettingsFormatException('not JSON: ${e.message}');
    }
    if (json is! Map<String, Object?>) {
      throw const SettingsFormatException('not a JSON object');
    }
    final declared = json['version'];
    if (declared is! int) {
      throw const SettingsFormatException('version must be an integer');
    }
    if (declared > version) throw NewerSettingsVersion(declared);
    final llm = json['llm'];
    if (llm != null && (llm is! String || llm.isEmpty)) {
      throw const SettingsFormatException(
        'llm must be a non-empty string or null',
      );
    }
    rejectSecretLike(json, where: 'settings');
    final share = json['share_tasks_with_cloud'];
    if (share != null && share is! bool) {
      throw const SettingsFormatException(
        'share_tasks_with_cloud must be a boolean',
      );
    }
    final rawProviders = json['providers'];
    if (rawProviders != null && rawProviders is! List) {
      throw const SettingsFormatException('providers must be a list');
    }
    final providers = [
      for (final p in rawProviders as List? ?? const [])
        ProviderConfig.fromJson(p),
    ];
    final ids = <String>{};
    for (final p in providers) {
      if (!ids.add(p.id)) {
        throw SettingsFormatException('two providers share the id "${p.id}"');
      }
    }
    return Settings(
      llm: llm as String?,
      providers: providers,
      shareTasksWithCloud: share as bool? ?? false,
      extra: {
        for (final e in json.entries)
          if (!_known.contains(e.key)) e.key: e.value,
      },
    );
  }

  static const _known = {
    'version',
    'llm',
    'providers',
    'share_tasks_with_cloud',
  };

  /// The file's text: compact JSON, keys sorted, unknown keys included.
  ///
  /// Throws [ArgumentError] when the result would be refused by [decode]
  /// — a secret-looking key or value somewhere in [extra]. What sai
  /// writes, sai can read back; a file that would be quarantined on the
  /// next start is never produced.
  String encode() {
    final text = _encode();
    try {
      rejectSecretLike(
        jsonDecode(text) as Map<String, Object?>,
        where: 'settings',
      );
    } on SettingsFormatException catch (e) {
      throw ArgumentError('refusing to write settings: ${e.reason}');
    }
    return text;
  }

  String _encode() => jsonEncode(
    SplayTreeMap<String, Object?>.of({
      ...extra,
      'version': version,
      'llm': llm,
      if (providers.isNotEmpty)
        'providers': [for (final p in providers) p.toJson()],
      // Off is the default and is not written: an untouched file stays
      // byte-identical across sai versions.
      if (shareTasksWithCloud) 'share_tasks_with_cloud': true,
    }),
  );
}
