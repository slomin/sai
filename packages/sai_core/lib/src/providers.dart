import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'app_info.dart';
import 'archive/archive.dart';
import 'archive/archive_root.dart';
import 'archive/event.dart';
import 'llm/factory.dart';
import 'llm/fake.dart';
import 'llm/provider.dart';
import 'llm/recorder.dart';
import 'llm/status.dart';
import 'secrets/keychain.dart';
import 'secrets/secret_store.dart';
import 'settings/provider_config.dart';
import 'settings/settings.dart';
import 'settings/store.dart';
import 'tasks/date.dart';
import 'tasks/lists.dart';
import 'tasks/projection.dart';
import 'tasks/sidebar.dart';
import 'tasks/store.dart';
import 'tasks/views.dart';

/// The application identity every client shows.
final appInfoProvider = Provider<AppInfo>(
  (ref) => const AppInfo(name: 'sai', version: saiVersion),
);

/// The line an empty shell shows until there is something to show.
final shellGreetingProvider = Provider<String>((ref) {
  final info = ref.watch(appInfoProvider);
  return '$info — nothing here yet';
});

/// The process environment, for the providers that resolve paths from
/// it. Tests override this instead of exporting variables.
final environmentProvider = Provider<Map<String, String>>(
  (ref) => Platform.environment,
);

/// The directory holding the event log. Tests and tools override this;
/// everyone else gets the platform default, which lives outside any repo.
final archiveRootProvider = Provider<Directory>(
  (ref) => resolveArchiveRoot(
    environment: ref.watch(environmentProvider),
    operatingSystem: Platform.operatingSystem,
  ),
);

/// The opened archive. Every client appends and reads through this single
/// instance; there is no other write path to the log. Disposal releases
/// the archive's lock handle so rebuilt providers never leak descriptors.
/// Event timestamps come from [clockProvider], so a test clock pins them.
final archiveProvider = FutureProvider<Archive>((ref) async {
  final archive = await Archive.open(
    ref.watch(archiveRootProvider),
    clock: ref.watch(clockProvider),
  );
  ref.onDispose(archive.close);
  return archive;
});

/// The `source` stamped on every event this process writes — which client
/// this is. No default on purpose: a wrong name would silently mislabel the
/// audit record, so each client must override this at startup with its
/// [EventSources] constant.
final eventSourceProvider = Provider<String>(
  (ref) => throw UnimplementedError(
    'override eventSourceProvider with the writing client, '
    'e.g. EventSources.tui',
  ),
);

/// The wall clock. Override in tests for deterministic "now".
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Today as a local calendar day, refreshed at each local midnight.
final todayProvider = NotifierProvider<TodayNotifier, CalendarDate>(
  TodayNotifier.new,
);

/// The task store and its projection, replayed from the archive. Read the
/// state for the current [TaskProjection]; use [TasksNotifier.store] for
/// commands — every mutation goes through it and lands here.
final tasksProvider = AsyncNotifierProvider<TasksNotifier, TaskProjection>(
  TasksNotifier.new,
);

/// The reactive shared view for any value-equal sidebar selection. Loading
/// and errors from task replay remain visible to clients unchanged.
final taskViewProvider = Provider.family<AsyncValue<TaskView>, SidebarSection>((
  ref,
  section,
) {
  final today = ref.watch(todayProvider);
  return ref
      .watch(tasksProvider)
      .whenData((projection) => taskView(projection, section, today: today));
});

/// The reactive sidebar counts and hierarchy from the same snapshot/day as
/// [taskViewProvider].
final sidebarProvider = Provider<AsyncValue<SidebarModel>>((ref) {
  final today = ref.watch(todayProvider);
  return ref
      .watch(tasksProvider)
      .whenData((projection) => sidebarModel(projection, today: today));
});

/// Whether the task store has a mutation to undo — false until
/// [tasksProvider] has settled. Recomputed on every commit: the
/// projection state changes whenever the undo stack does.
final canUndoProvider = Provider<bool>((ref) {
  if (ref.watch(tasksProvider) case AsyncData()) {
    return ref.read(tasksProvider.notifier).store.canUndo;
  }
  return false;
});

/// The sidebar section a client is showing. Opens on Today — the list
/// the day starts from; quick capture still lands in the Inbox. Shared
/// so the clients (#37, #41) and their menus steer the same state.
final selectedSectionProvider =
    NotifierProvider<SelectedSection, SidebarSection>(SelectedSection.new);

/// Whether the chat pane is shown. Shell chrome; the pane's content is
/// #34/#39.
final chatVisibleProvider = NotifierProvider<ChatVisible, bool>(
  ChatVisible.new,
);

/// The settings file (ADR 0006): `SAI_SETTINGS_FILE`, else
/// `settings.json` in sai's data directory. Independent of the archive
/// root, so a test that overrides [archiveRootProvider] must override
/// this too — the harnesses do.
final settingsFileProvider = Provider<File>(
  (ref) => resolveSettingsFile(
    environment: ref.watch(environmentProvider),
    operatingSystem: Platform.operatingSystem,
  ),
);

/// Non-secret settings, read at first use and written on every change.
/// Use [SettingsNotifier.selectLlm] to switch the active provider.
final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(
  SettingsNotifier.new,
);

/// Where secrets live (ADR 0008): the Keychain on macOS, memory anywhere
/// else. Every test harness overrides this with an [InMemorySecretStore]
/// — nothing under `test/` may reach the login keychain.
final secretStoreProvider = Provider<SecretStore>(
  (ref) => Platform.isMacOS ? KeychainSecretStore() : InMemorySecretStore(),
);

/// Whether a provider's credential is there. [CredentialStatus.none] is a
/// provider that takes no key; the others say what the store answered.
enum CredentialStatus { none, set, missing, unavailable }

/// Writes credentials through [secretStoreProvider] and bumps a revision
/// so [credentialStatusProvider] re-reads. Values never enter state.
final credentialsProvider = NotifierProvider<CredentialsNotifier, int>(
  CredentialsNotifier.new,
);

/// The credential status of the configured provider [id] — the built-in
/// fake and unknown ids take no key. Re-evaluated whenever
/// [credentialsProvider] writes or the configuration changes.
final credentialStatusProvider = Provider.family<CredentialStatus, String>((
  ref,
  id,
) {
  ref.watch(credentialsProvider);
  final account = ref.watch(
    settingsProvider.select((s) => s.provider(id)?.credential),
  );
  if (account == null) return CredentialStatus.none;
  try {
    return ref.watch(secretStoreProvider).has(account)
        ? CredentialStatus.set
        : CredentialStatus.missing;
  } on SecretStoreException {
    return CredentialStatus.unavailable;
  }
});

/// The factories this build can turn a [ProviderConfig] into, by kind.
/// #22 adds `openai_compatible`.
final llmFactoriesProvider = Provider<Map<String, LlmProviderFactory>>(
  (ref) => const {'fake': fakeProviderFactory},
);

/// The providers that ship with every build, needing no configuration,
/// as constructors: the cache below decides when one is built. A
/// configured provider with the same id replaces the built-in one.
final builtinLlmsProvider = Provider<List<LlmProvider Function()>>(
  (ref) => [FakeLlmProvider.new],
);

/// The open providers, keyed by what built them, so a configuration edit
/// rebuilds only the providers whose configuration changed and closes
/// only the ones that are gone — a call running on an untouched provider
/// is never cut. Closes everything when the container goes.
final _llmCacheProvider = Provider<_LlmCache>((ref) {
  final cache = _LlmCache();
  ref.onDispose(cache.closeAll);
  return cache;
});

/// Every [LlmProvider] this build can offer: the built-ins plus one per
/// configured provider whose kind has a factory. Watches only the
/// configured list, not the selection — selecting must never rebuild
/// (and so close) a provider, or a running call would be cut.
final installedLlmsProvider = Provider<List<LlmProvider>>((ref) {
  final configs = ref.watch(settingsProvider.select((s) => s.providers));
  final factories = ref.watch(llmFactoriesProvider);
  final secrets = ref.watch(secretStoreProvider);
  final cache = ref.watch(_llmCacheProvider);
  final wanted = <String, LlmProvider Function()>{};
  final configured = <String>[];
  for (final config in configs) {
    final factory = factories[config.kind];
    if (factory == null) continue;
    wanted['config:${jsonEncode(config.toJson())}'] = () =>
        factory(config, secrets);
    configured.add(config.id);
  }
  final builtins = ref.watch(builtinLlmsProvider);
  for (var i = 0; i < builtins.length; i++) {
    wanted['builtin:$i'] = builtins[i];
  }
  final providers = cache.sync(wanted);
  final taken = configured.toSet();
  return [
    for (final key in wanted.keys)
      if (key.startsWith('builtin:') && !taken.contains(providers[key]!.id))
        providers[key]!,
    for (final key in wanted.keys)
      if (key.startsWith('config:')) providers[key]!,
  ];
});

/// The installed providers by id. Throws [StateError] on a duplicate id
/// at first read. Closing is the cache's job, not this map's: the map is
/// rebuilt on every configuration change, the providers are not.
final llmRegistryProvider = Provider<Map<String, LlmProvider>>((ref) {
  final installed = ref.watch(installedLlmsProvider);
  final registry = <String, LlmProvider>{};
  for (final provider in installed) {
    if (registry.containsKey(provider.id)) {
      // Refusing the registry must not leak what was already built.
      for (final built in installed) {
        built.close();
      }
      throw StateError('two LLM providers share the id "${provider.id}"');
    }
    registry[provider.id] = provider;
  }
  return Map.unmodifiable(registry);
});

/// The selected provider, or null when nothing is selected or the
/// selected id is not installed. Selection is an app-level setting, not
/// per conversation.
final activeLlmProvider = Provider<LlmProvider?>((ref) {
  final id = ref.watch(settingsProvider).llm;
  if (id == null) return null;
  return ref.watch(llmRegistryProvider)[id];
});

/// The status-bar line naming the active LLM provider and its privacy
/// tag — the same words in every client (`llm/status.dart`).
final llmStatusProvider = Provider<String>((ref) {
  final settings = ref.watch(settingsProvider);
  if (settings.problem != null) return unreadableSettingsStatus;
  final id = settings.llm;
  if (id == null) return noProviderStatus;
  final active = ref.watch(activeLlmProvider);
  if (active == null) {
    final config = settings.provider(id);
    if (config == null) return missingProviderStatus(id);
    return unavailableKindStatus(id, config.kind);
  }
  return llmStatusLine(active) +
      switch (ref.watch(credentialStatusProvider(id))) {
        CredentialStatus.missing => missingCredentialSuffix,
        CredentialStatus.unavailable => unavailableSecretsSuffix,
        CredentialStatus.none || CredentialStatus.set => '',
      };
});

/// A recorder bound to the archive and this client's source — how a
/// caller obtains a call that records itself. Deliberately independent
/// of [activeLlmProvider]: switching never disturbs a running call.
final llmRecorderProvider = FutureProvider<LlmRecorder>(
  (ref) async => LlmRecorder(
    archive: await ref.watch(archiveProvider.future),
    source: ref.watch(eventSourceProvider),
    clock: ref.watch(clockProvider),
  ),
);

/// Loads the settings file once and writes it on every change. One
/// store per build: it remembers whether the file belongs to a newer sai.
class SettingsNotifier extends Notifier<Settings> {
  late SettingsStore _store;

  @override
  Settings build() {
    _store = SettingsStore(
      ref.watch(settingsFileProvider),
      clock: ref.watch(clockProvider),
    );
    return _store.load();
  }

  /// Selects the provider with [id] (null for none), writing the file
  /// before the state changes. Throws [StateError] when the file belongs
  /// to a newer sai and must not be overwritten.
  void selectLlm(String? id) => _commit(state.withLlm(id));

  /// Adds [config], or replaces the provider with its id in place.
  void upsertProvider(ProviderConfig config) =>
      _commit(state.withProvider(config));

  /// Removes the provider [id], clearing its selection if it was active.
  /// The credential, if any, stays in the secret store — removing a
  /// configuration is not revoking a key; [CredentialsNotifier.clear]
  /// is.
  void removeProvider(String id) => _commit(state.withoutProvider(id));

  void _commit(Settings next) {
    _store.save(next);
    state = next;
  }
}

/// Write path for credentials. Reads stay on [credentialStatusProvider].
class CredentialsNotifier extends Notifier<int> {
  @override
  int build() => 0;

  /// Stores [value] under the account of the configured provider [id]
  /// (`provider:<id>` unless its configuration names another). Throws
  /// [StateError] for an unconfigured id or one that takes no key, and
  /// [SecretStoreException] when the store refuses.
  void set(String id, String value) {
    ref.read(secretStoreProvider).write(_account(id), value);
    state++;
  }

  /// Removes the credential of [id]; returns whether there was one.
  bool clear(String id) => clearAccount(_account(id));

  /// Removes the secret under [account] whether or not a provider still
  /// names it — how a key left behind by a removed provider is revoked.
  bool clearAccount(String account) {
    final gone = ref.read(secretStoreProvider).delete(account);
    state++;
    return gone;
  }

  /// Whether [account] holds a secret, configured or not.
  CredentialStatus statusOf(String account) {
    try {
      return ref.read(secretStoreProvider).has(account)
          ? CredentialStatus.set
          : CredentialStatus.missing;
    } on SecretStoreException {
      return CredentialStatus.unavailable;
    }
  }

  String _account(String id) {
    final config = ref.read(settingsProvider).provider(id);
    if (config == null) {
      throw StateError("provider '$id' is not configured");
    }
    final account = config.credential;
    if (account == null) {
      throw StateError("provider '$id' takes no credential");
    }
    return account;
  }
}

/// Open providers by build key. [sync] builds what is missing, closes
/// what is no longer wanted, and keeps the rest untouched.
final class _LlmCache {
  final _open = <String, LlmProvider>{};

  Map<String, LlmProvider> sync(Map<String, LlmProvider Function()> wanted) {
    for (final key in _open.keys.toList()) {
      if (!wanted.containsKey(key)) {
        _open.remove(key)!.close();
      }
    }
    for (final e in wanted.entries) {
      _open.putIfAbsent(e.key, e.value);
    }
    return Map.unmodifiable(_open);
  }

  void closeAll() {
    for (final provider in _open.values) {
      provider.close();
    }
    _open.clear();
  }
}

class SelectedSection extends Notifier<SidebarSection> {
  @override
  SidebarSection build() => const ListSection(TaskList.today);

  void select(SidebarSection section) => state = section;
}

/// Owns the one-shot timer that turns the wall clock into a reactive local
/// calendar day. A late callback (sleep/wake or clock movement) reads the
/// clock again before scheduling the following midnight.
class TodayNotifier extends Notifier<CalendarDate> {
  Timer? _timer;
  late DateTime Function() _clock;

  @override
  CalendarDate build() {
    _timer?.cancel();
    _clock = ref.watch(clockProvider);
    ref.onDispose(() => _timer?.cancel());
    final now = _clock();
    _schedule(now);
    return CalendarDate.fromLocal(now);
  }

  void _schedule(DateTime now) {
    _timer?.cancel();
    final local = now.toLocal();
    final midnight = DateTime(local.year, local.month, local.day + 1);
    final delay = midnight.difference(local);
    _timer = Timer(delay.isNegative ? Duration.zero : delay, _rollOver);
  }

  void _rollOver() {
    final now = _clock();
    state = CalendarDate.fromLocal(now);
    _schedule(now);
  }
}

class ChatVisible extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle() => state = !state;
}

/// Holds the process's one [TaskStore] and mirrors its [TaskStore.changes]
/// into provider state.
class TasksNotifier extends AsyncNotifier<TaskProjection> {
  TaskStore? _store;

  /// The store, for commands. Mutations made here show up in the provider
  /// state as they commit.
  ///
  /// Throws [StateError] until [build] has settled — and again during a
  /// rebuild, whose disposal clears the previous store rather than handing
  /// out a disposed one. Await the provider's future first.
  TaskStore get store =>
      _store ??
      (throw StateError(
        'tasksProvider has no open store yet — await the provider future '
        'before using it',
      ));

  @override
  Future<TaskProjection> build() async {
    final archive = await ref.watch(archiveProvider.future);
    final store = await TaskStore.open(
      archive,
      source: ref.watch(eventSourceProvider),
    );
    _store = store;
    final subscription = store.changes.listen(
      (projection) => state = AsyncData(projection),
    );
    ref.onDispose(() {
      subscription.cancel();
      store.dispose();
      if (identical(_store, store)) {
        _store = null;
      }
    });
    return store.projection;
  }
}
