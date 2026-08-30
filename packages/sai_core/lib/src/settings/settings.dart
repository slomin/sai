import 'dart:collection';
import 'dart:convert';

import '../tasks/lists.dart';
import 'provider_config.dart';
import 'workspace.dart';

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
    this.reasoningOn = false,
    this.workspace = WorkspaceState.empty,
    this.setupDone = false,
    this.finishedTaskVisibility = FinishedTaskVisibility.endOfDay,
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

  /// Whether a model may think before it answers (#34): off asks the
  /// backend not to (`reasoning_effort: none` and llama.cpp's
  /// `chat_template_kwargs.enable_thinking`) and the clients show no
  /// thinking; on lets it, and the clients show what it thought. Off by
  /// default: faster, and the answer is what matters.
  final bool reasoningOn;

  /// Where the workspace was left (#76): ids and UI preferences a client
  /// restores at launch after checking them against the projection.
  final WorkspaceState workspace;

  /// Whether first-run setup was completed (#40): the person chose to
  /// start empty or finished an import. Written only on that choice —
  /// an untouched first launch writes nothing — and never unset.
  final bool setupDone;

  /// When a finished task leaves its working views (#97): end of the
  /// local day by default, so the day stays reviewable; immediate keeps
  /// the confirm-and-collapse.
  final FinishedTaskVisibility finishedTaskVisibility;

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
    reasoningOn: reasoningOn,
    workspace: workspace,
    setupDone: setupDone,
    finishedTaskVisibility: finishedTaskVisibility,
    extra: extra,
  );

  /// The same settings with the reasoning display set. Clears
  /// [problem] like [withLlm].
  Settings withReasoning(bool show) => Settings(
    llm: llm,
    providers: providers,
    shareTasksWithCloud: shareTasksWithCloud,
    reasoningOn: show,
    workspace: workspace,
    setupDone: setupDone,
    finishedTaskVisibility: finishedTaskVisibility,
    extra: extra,
  );

  /// The same settings with the cloud-sharing switch set. Clears
  /// [problem] like [withLlm].
  Settings withShareTasksWithCloud(bool share) => Settings(
    llm: llm,
    providers: providers,
    shareTasksWithCloud: share,
    reasoningOn: reasoningOn,
    workspace: workspace,
    setupDone: setupDone,
    finishedTaskVisibility: finishedTaskVisibility,
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
      reasoningOn: reasoningOn,
      workspace: workspace,
      setupDone: setupDone,
      finishedTaskVisibility: finishedTaskVisibility,
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
    reasoningOn: reasoningOn,
    workspace: workspace,
    setupDone: setupDone,
    finishedTaskVisibility: finishedTaskVisibility,
    extra: extra,
  );

  /// The same settings with the workspace remembered as [state]. Clears
  /// [problem] like [withLlm].
  Settings withWorkspace(WorkspaceState state) => Settings(
    llm: llm,
    providers: providers,
    shareTasksWithCloud: shareTasksWithCloud,
    reasoningOn: reasoningOn,
    workspace: state,
    setupDone: setupDone,
    finishedTaskVisibility: finishedTaskVisibility,
    extra: extra,
  );

  /// The same settings with setup marked done. Clears [problem] like
  /// [withLlm].
  Settings withSetupDone() => Settings(
    llm: llm,
    providers: providers,
    shareTasksWithCloud: shareTasksWithCloud,
    reasoningOn: reasoningOn,
    workspace: workspace,
    setupDone: true,
    finishedTaskVisibility: finishedTaskVisibility,
    extra: extra,
  );

  /// The same settings with the finished-task policy set (#97). Clears
  /// [problem] like [withLlm].
  Settings withFinishedTaskVisibility(FinishedTaskVisibility visibility) =>
      Settings(
        llm: llm,
        providers: providers,
        shareTasksWithCloud: shareTasksWithCloud,
        reasoningOn: reasoningOn,
        workspace: workspace,
        setupDone: setupDone,
        finishedTaskVisibility: visibility,
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
    final reasoning = json['reasoning'];
    if (reasoning != null && reasoning is! bool) {
      throw const SettingsFormatException('reasoning must be a boolean');
    }
    final finished = json[finishedTaskVisibilityKey];
    if (finished != null && finished is! String) {
      throw const SettingsFormatException(
        'finished_task_visibility must be end_of_day or immediate',
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
      reasoningOn: reasoning as bool? ?? false,
      workspace: WorkspaceState.fromJson(json['workspace']),
      // Read leniently like the workspace: a value this sai does not
      // know is "not done", and, being a known key, it is not carried.
      setupDone: json['setup'] == setupDoneValue,
      // A word this sai does not know is the default, and, being a known
      // key, it is not carried either.
      finishedTaskVisibility:
          (finished == null
              ? null
              : FinishedTaskVisibility.fromWire(finished as String)) ??
          FinishedTaskVisibility.endOfDay,
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
    'reasoning',
    'workspace',
    'setup',
    finishedTaskVisibilityKey,
  };

  /// The key holding [finishedTaskVisibility].
  static const finishedTaskVisibilityKey = 'finished_task_visibility';

  /// What `setup` holds once first-run setup is complete.
  static const setupDoneValue = 'done';

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
      if (reasoningOn) 'reasoning': true,
      if (!workspace.isEmpty) 'workspace': workspace.toJson(),
      if (setupDone) 'setup': setupDoneValue,
      if (finishedTaskVisibility != FinishedTaskVisibility.endOfDay)
        finishedTaskVisibilityKey: finishedTaskVisibility.wireName,
    }),
  );
}
