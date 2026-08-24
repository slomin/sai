import 'dart:collection';
import 'dart:convert';

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

/// The settings value: the selected provider, plus whatever a newer or
/// later sai stored, carried verbatim so a write never erases it.
final class Settings {
  const Settings({this.llm, this.problem, this.extra = const {}});

  /// Nothing selected, nothing wrong.
  static const empty = Settings();

  /// The format this sai writes.
  static const version = 0;

  /// Id of the selected `LlmProvider`, or null for none.
  final String? llm;

  /// Why the stored settings could not be used, when they could not be —
  /// shown to the user, never written.
  final String? problem;

  /// Keys this sai does not know, exactly as read.
  final Map<String, Object?> extra;

  /// The same settings with [id] selected. Clears [problem]: a write
  /// after a quarantine starts the file fresh.
  Settings withLlm(String? id) => Settings(llm: id, extra: extra);

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
    return Settings(
      llm: llm as String?,
      extra: {
        for (final e in json.entries)
          if (e.key != 'version' && e.key != 'llm') e.key: e.value,
      },
    );
  }

  /// The file's text: compact JSON, keys sorted, unknown keys included.
  String encode() => jsonEncode(
    SplayTreeMap<String, Object?>.of({
      ...extra,
      'version': version,
      'llm': llm,
    }),
  );
}
