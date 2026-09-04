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
    this.llmFallback = const [],
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

  /// Id of the first-choice `LlmProvider`, or null for none. The head of
  /// the preference order (#62), and a plain string on purpose: an older
  /// sai reads this key alone and selects exactly this provider.
  final String? llm;

  /// The ids tried after [llm], in order, when it cannot answer (#62):
  /// what `llm_fallback` holds. Empty while there is no fallback, and
  /// then not written at all.
  final List<String> llmFallback;

  /// The preference order: [llm] and the ids behind it, each once. Empty
  /// while nothing is selected — a tail without a head is not an order,
  /// and an older sai reading `llm` alone sees the same nothing.
  List<String> get llmOrder {
    final head = llm;
    if (head == null) return const [];
    final order = [head];
    for (final id in llmFallback) {
      if (!order.contains(id)) order.add(id);
    }
    return List.unmodifiable(order);
  }

  /// The order as one word, so a riverpod `select` on it wakes only when
  /// the order itself moves — a workspace save must not re-resolve the
  /// provider. Provider ids carry no space (`settings-v0`).
  String get llmOrderKey => llmOrder.join(' ');

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

  /// The same settings with [id] as the first choice — or, for null,
  /// nothing selected at all. It sets the order's first entry, never the
  /// whole order (#62): an id already in the order moves to the front and
  /// nothing is dropped, a new one takes the head's place and the
  /// arranged tail behind it stands. The order grows only where a person
  /// arranges it. Clears [problem]: a write after a quarantine starts the
  /// file fresh.
  Settings withLlm(String? id) {
    if (id == null) return withLlmOrder(const []);
    final order = llmOrder;
    return withLlmOrder(
      order.contains(id)
          ? [id, ...order.where((entry) => entry != id)]
          : [id, ...order.skip(1)],
    );
  }

  /// The same settings with the preference order set (#62): the first
  /// entry becomes [llm], the rest [llmFallback]. A repeated id keeps the
  /// first place it takes. Clears [problem] like [withLlm].
  Settings withLlmOrder(List<String> order) {
    final unique = <String>[];
    for (final id in order) {
      if (id.isNotEmpty && !unique.contains(id)) unique.add(id);
    }
    return Settings(
      llm: unique.isEmpty ? null : unique.first,
      llmFallback: List.unmodifiable(unique.skip(1)),
      providers: providers,
      shareTasksWithCloud: shareTasksWithCloud,
      reasoningOn: reasoningOn,
      workspace: workspace,
      setupDone: setupDone,
      finishedTaskVisibility: finishedTaskVisibility,
      extra: extra,
    );
  }

  /// The same settings with the reasoning display set. Clears
  /// [problem] like [withLlm].
  Settings withReasoning(bool show) => Settings(
    llm: llm,
    llmFallback: llmFallback,
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
    llmFallback: llmFallback,
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
      llmFallback: llmFallback,
      providers: next,
      shareTasksWithCloud: shareTasksWithCloud,
      reasoningOn: reasoningOn,
      workspace: workspace,
      setupDone: setupDone,
      finishedTaskVisibility: finishedTaskVisibility,
      extra: extra,
    );
  }

  /// The same settings without the provider [id]; it leaves the
  /// preference order wherever it stood, so the order never names a
  /// provider that is gone and the next entry takes a vacated head.
  Settings withoutProvider(String id) {
    final order = [
      for (final entry in llmOrder)
        if (entry != id) entry,
    ];
    return Settings(
      llm: order.isEmpty ? null : order.first,
      llmFallback: List.unmodifiable(order.skip(1)),
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
  }

  /// The same settings with the workspace remembered as [state]. Clears
  /// [problem] like [withLlm].
  Settings withWorkspace(WorkspaceState state) => Settings(
    llm: llm,
    llmFallback: llmFallback,
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
    llmFallback: llmFallback,
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
        llmFallback: llmFallback,
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
    final fallback = json[llmFallbackKey];
    if (fallback != null &&
        (fallback is! List ||
            fallback.any((id) => id is! String || id.isEmpty))) {
      throw const SettingsFormatException(
        'llm_fallback must be a list of non-empty strings',
      );
    }
    // Normalised as read: a tail entry repeating the head or itself says
    // nothing, and a tail without a head is not an order at all — an
    // older sai reading `llm` alone sees the same nothing. Being a known
    // key, what is dropped is not written again.
    final tail = <String>[];
    if (llm != null) {
      for (final id in fallback as List? ?? const []) {
        if (id != llm && !tail.contains(id)) tail.add(id as String);
      }
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
      llmFallback: List.unmodifiable(tail),
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
    llmFallbackKey,
    'providers',
    'share_tasks_with_cloud',
    'reasoning',
    'workspace',
    'setup',
    finishedTaskVisibilityKey,
  };

  /// The key holding [llmFallback] — the order behind [llm].
  static const llmFallbackKey = 'llm_fallback';

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
      // Omitted while there is no fallback, so a single choice writes the
      // file an older sai wrote.
      if (llmOrder.length > 1) llmFallbackKey: llmOrder.skip(1).toList(),
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
