import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'app_info.dart';
import 'identity.dart';
import 'archive/archive.dart';
import 'chat/chat.dart';
import 'archive/archive_root.dart';
import 'archive/event.dart';
import 'archive/verify_state.dart';
import 'llm/connection.dart';
import 'llm/failure.dart';
import 'llm/builtins.dart';
import 'llm/factory.dart';
import 'llm/openai_compatible/provider.dart';
import 'llm/privacy.dart';
import 'llm/probe.dart';
import 'llm/provider.dart';
import 'llm/recorder.dart';
import 'llm/status.dart';
import 'secrets/keychain.dart';
import 'secrets/secret_store.dart';
import 'settings/provider_config.dart';
import 'settings/settings.dart';
import 'settings/store.dart';
import 'settings/workspace.dart';
import 'tasks/date.dart';
import 'tasks/lists.dart';
import 'tasks/model.dart';
import 'tasks/projection.dart';
import 'tasks/sidebar.dart';
import 'tasks/store.dart';
import 'tasks/views.dart';
import 'things/import_state.dart';
import 'things/things_db.dart';
import 'things/things_import.dart';
import 'things/things_mapping.dart';
import 'things/things_source.dart';

/// Which installed sai this process is (ADR 0019). Stable unless a client
/// says otherwise: the app maps its Flutter flavor at startup, the dev
/// terminal client overrides it from its own entry point.
final identityProvider = Provider<SaiIdentity>((ref) => SaiIdentity.stable);

/// The application identity every client shows.
final appInfoProvider = Provider<AppInfo>(
  (ref) => AppInfo(name: ref.watch(identityProvider).name, version: saiVersion),
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
    identity: ref.watch(identityProvider),
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

/// Opens the process task store. This narrow indirection makes the async
/// provider lifecycle deterministic in tests without abstracting the store
/// used by clients.
final taskStoreOpenerProvider = Provider<TaskStoreOpener>(
  (ref) => TaskStore.open,
);

typedef TaskStoreOpener = Future<TaskStore> Function(
  Archive archive, {
  required String source,
});

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

/// How many lines the archive holds, for the clients' archive line. Every
/// writer appends there — the task store, the chat, the recorder — so the
/// count is read from the log's head and refreshed whenever the tasks or
/// the conversation move on, not derived from the task projection alone.
final archiveLineCountProvider = FutureProvider<int>((ref) async {
  ref.watch(archiveRevisionProvider);
  final archive = await ref.watch(archiveProvider.future);
  ref.watch(tasksProvider);
  ref.watch(chatProvider);
  return (await archive.head()).count;
});

/// The task row a client has selected, or null. A client clears it when
/// the task leaves the view it is showing (#72); the inspector (#74) and
/// restored workspace state (#76) read the same value.
/// Events and bytes the archive holds (#40), re-read whenever the log
/// moves for the same reasons as [archiveLineCountProvider].
/// Bumped by a writer the log's other watchers cannot see — a provider
/// test recorded straight through [LlmRecorder] — so the counts re-read.
final archiveRevisionProvider = NotifierProvider<ArchiveRevision, int>(
  ArchiveRevision.new,
);

class ArchiveRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

final archiveStatsProvider = FutureProvider<ArchiveStats>((ref) async {
  ref.watch(tasksProvider);
  ref.watch(chatProvider.select((s) => s.turns.length));
  ref.watch(archiveRevisionProvider);
  final archive = await ref.watch(archiveProvider.future);
  final head = await archive.head();
  return ArchiveStats(count: head.count, bytes: await archive.byteSize());
});

/// The on-demand integrity pass (#40): [Archive.verify] behind a
/// button. A notifier rather than a future provider on purpose — the
/// walk takes the writer lock, and a failure must land once, not be
/// retried ten times over the whole log.
final archiveVerifyProvider = NotifierProvider<ArchiveVerify, VerifyState>(
  ArchiveVerify.new,
);

/// The assistant header's light (#40): the active provider probed when
/// it is selected, every [Connection.probeEvery], on [Connection.refresh]
/// and after a call fails. A provider that cannot be probed (the fake)
/// is ready; no provider, a misconfigured one or a missing key is down.
final connectionProvider = NotifierProvider<Connection, ConnectionStatus>(
  Connection.new,
);

/// How often the light asks again — null never asks on a timer. Widget
/// tests override it: a periodic timer would outlive the test.
final connectionProbeEveryProvider = Provider<Duration?>(
  (ref) => Connection.probeEvery,
);

final selectedTaskProvider = NotifierProvider<SelectedTask, TaskId?>(
  SelectedTask.new,
);

/// Whether a model may think before it answers, as settings hold it
/// (`reasoning`, off by default): off is sent to the backend as
/// `reasoning_effort: none`, on is the model's default and shown.
final reasoningProvider = Provider<bool>(
  (ref) => ref.watch(settingsProvider.select((s) => s.reasoningOn)),
);

/// The conversation (#34): transcript, the answer as it streams, and
/// the last refused send. Lives here, not in a pane, so a pane that
/// unmounts (the app's below its breakpoint) does not lose the talk.
final chatProvider = NotifierProvider<ChatNotifier, ChatState>(
  ChatNotifier.new,
);

/// Whether the chat pane is shown. Shell chrome; the pane's content is
/// #34/#39.
final chatVisibleProvider = NotifierProvider<ChatVisible, bool>(
  ChatVisible.new,
);

/// The areas the sidebar shows folded (#76).
final collapsedAreasProvider = NotifierProvider<CollapsedAreas, Set<AreaId>>(
  CollapsedAreas.new,
);

/// The workspace as it stands, in the form settings remember it (#76):
/// the selected section and task, the folded areas, the assistant pane.
/// A client writes it through [SettingsNotifier.setWorkspace] and restores
/// it with `restoreWorkspace`.
final workspaceStateProvider = Provider<WorkspaceState>((ref) {
  final collapsed = ref.watch(collapsedAreasProvider);
  return WorkspaceState(
    section: sectionKey(ref.watch(selectedSectionProvider)),
    task: ref.watch(selectedTaskProvider)?.toString(),
    collapsedAreas: [for (final id in collapsed) '$id']..sort(),
    assistantVisible: ref.watch(chatVisibleProvider),
  );
});

/// The settings file (ADR 0006): `SAI_SETTINGS_FILE`, else
/// `settings.json` in sai's data directory. Independent of the archive
/// root, so a test that overrides [archiveRootProvider] must override
/// this too — the harnesses do.
final settingsFileProvider = Provider<File>(
  (ref) => resolveSettingsFile(
    environment: ref.watch(environmentProvider),
    operatingSystem: Platform.operatingSystem,
    identity: ref.watch(identityProvider),
  ),
);

/// Non-secret settings, read at first use and written on every change.
/// Use [SettingsNotifier.selectLlm] to switch the active provider.
final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(
  SettingsNotifier.new,
);

/// Where secrets live (ADR 0008): the Keychain on macOS, under this
/// flavor's service, memory anywhere else. Every test harness overrides
/// this with an [InMemorySecretStore] — nothing under `test/` may reach
/// the login keychain.
final secretStoreProvider = Provider<SecretStore>(
  (ref) => Platform.isMacOS
      ? KeychainSecretStore(
          service: ref.watch(identityProvider).keychainService,
        )
      : InMemorySecretStore(),
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
final llmFactoriesProvider = Provider<Map<String, LlmProviderFactory>>(
  (ref) => const {
    'fake': fakeProviderFactory,
    'openai_compatible': openAiCompatibleFactory,
  },
);

/// Configured providers whose kind is known but whose configuration the
/// factory refused, by id, with what is missing. Not built, not in the
/// registry; the status line and the dialogs name them.
final misconfiguredLlmsProvider = Provider<Map<String, String>>((ref) {
  final configs = ref.watch(settingsProvider.select((s) => s.providers));
  final factories = ref.watch(llmFactoriesProvider);
  final out = <String, String>{};
  for (final config in configs) {
    if (!factories.containsKey(config.kind)) continue;
    final missing = missingForKind(config);
    if (missing != null) out[config.id] = missing;
  }
  return out;
});

/// The credential suffix both clients append to a provider line.
String credentialSuffix(CredentialStatus status, ProviderConfig? config) =>
    switch (status) {
      CredentialStatus.none => '',
      CredentialStatus.set =>
        config != null && config.endpoint != null && !config.keyBound
            ? reenterCredentialSuffix
            : setCredentialSuffix,
      CredentialStatus.missing => missingCredentialSuffix,
      CredentialStatus.unavailable => unavailableSecretsSuffix,
    };

/// The providers that ship with every build, needing no configuration,
/// as constructors: the cache below decides when one is built. A
/// configured provider with the same id replaces the built-in one.
/// `llm/builtins.dart` lists them; the test harnesses override this with
/// the fake alone.
final builtinLlmsProvider = Provider<List<LlmProvider Function()>>(
  (ref) => builtinLlms(ref.watch(secretStoreProvider)),
);

/// What a first run selects (#23): LM Studio on this Mac. Applied only
/// while the settings file does not exist; the harnesses override it
/// with null so a fresh test container selects nothing.
final defaultLlmIdProvider = Provider<String?>((ref) => defaultLlmId);

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
  final misconfigured = ref.watch(misconfiguredLlmsProvider);
  final bindings = <String, String?>{};
  for (final config in configs) {
    final factory = factories[config.kind];
    if (factory == null || misconfigured.containsKey(config.id)) continue;
    // The key binding is live state, not build state: storing a key must
    // not rebuild (and so close) the provider a call may be running on.
    final key = 'config:${jsonEncode(config.unbound.toJson())}';
    wanted[key] = () => factory(config, secrets);
    bindings[key] = config.credentialOrigin;
  }
  final builtins = ref.watch(builtinLlmsProvider);
  for (var i = 0; i < builtins.length; i++) {
    wanted['builtin:$i'] = builtins[i];
  }
  final providers = cache.sync(wanted);
  for (final e in bindings.entries) {
    if (providers[e.key] case final OpenAiCompatibleProvider p) {
      p.credentialOrigin = e.value;
    }
  }
  // A configured id hides the built-in with that id whether or not the
  // configuration can be built: a misconfigured or unknown-kind `lan`
  // must read as such, never route to the shipped endpoint.
  final taken = {for (final c in configs) c.id};
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

/// The privacy policy (#27) as settings hold it. Read per call by the
/// recorder, watched by the status line.
final privacyPolicyProvider = Provider<PrivacyPolicy>(
  (ref) => PrivacyPolicy(
    shareTasksWithCloud: ref.watch(
      settingsProvider.select((s) => s.shareTasksWithCloud),
    ),
  ),
);

/// The warning both clients show for the active provider — a cloud one
/// while sharing is off — or null when there is nothing to say.
final activeLlmWarningProvider = Provider<String?>((ref) {
  final active = ref.watch(activeLlmProvider);
  if (active == null) return null;
  return selectionWarning(active, ref.watch(privacyPolicyProvider));
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
    final missing = ref.watch(misconfiguredLlmsProvider)[id];
    if (missing != null) return misconfiguredStatus(id, missing);
    return unavailableKindStatus(id, config.kind);
  }
  return llmStatusLine(active, policy: ref.watch(privacyPolicyProvider)) +
      switch (ref.watch(credentialStatusProvider(id))) {
        CredentialStatus.missing => missingCredentialSuffix,
        CredentialStatus.unavailable => unavailableSecretsSuffix,
        CredentialStatus.none || CredentialStatus.set => '',
      };
});

/// What the endpoint of provider [id] says about itself, asked once per
/// registry build and again on `ref.invalidate`. A provider that cannot
/// be probed (the fake, an unknown id) answers [EndpointHealth.unknown].
/// Not a call: nothing is recorded.
final endpointInfoProvider = FutureProvider.autoDispose
    .family<EndpointInfo, String>((ref, id) async {
      final provider = ref.watch(llmRegistryProvider)[id];
      if (provider case final LlmEndpointProbe probe) return probe.probe();
      return const EndpointInfo();
    });

/// How a Things snapshot is read (#40): off the main isolate in the
/// clients, replaced by a direct read in a widget test.
final thingsSnapshotReaderProvider =
    Provider<Future<ThingsSnapshot> Function(String path)>(
      (ref) => readThingsSnapshot,
    );

/// The Things import as a flow both clients can render (#40): find or
/// name the database, preview what a run would do, run it, and say what
/// stood in the way. One run at a time; a step that finishes after
/// [ThingsImportNotifier.reset] is dropped.
final thingsImportProvider =
    NotifierProvider<ThingsImportNotifier, ThingsImportState>(
      ThingsImportNotifier.new,
    );

/// A recorder bound to the archive and this client's source — how a
/// caller obtains a call that records itself. Deliberately independent
/// of [activeLlmProvider]: switching never disturbs a running call.
final llmRecorderProvider = FutureProvider<LlmRecorder>((ref) async {
  // The policy is read per call, through the container rather than this
  // ref: a flipped switch governs the next call without rebuilding the
  // recorder, and a recorder held across a rebuild (the archive
  // reopened, say) keeps working instead of tripping on a stale ref.
  final container = ref.container;
  return LlmRecorder(
    archive: await ref.watch(archiveProvider.future),
    source: ref.watch(eventSourceProvider),
    clock: ref.watch(clockProvider),
    policy: () => container.read(privacyPolicyProvider),
  );
});

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
    // A first run — no file yet — selects the built-in default without
    // writing anything; a file that says `"llm": null` means none.
    final fresh = !_store.file.existsSync();
    final settings = _store.load();
    if (fresh && settings.llm == null) {
      return settings.withLlm(ref.watch(defaultLlmIdProvider));
    }
    return settings;
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

  /// Sets the cloud-sharing switch (#27).
  void setShareTasksWithCloud(bool share) =>
      _commit(state.withShareTasksWithCloud(share));

  void setReasoning(bool show) => _commit(state.withReasoning(show));

  /// Remembers where the workspace was left (#76). A no-op when nothing
  /// changed, so a client may call it on every selection.
  /// Records that first-run setup is complete (#40); a second call
  /// writes nothing.
  void markSetupDone() {
    if (state.setupDone) return;
    _commit(state.withSetupDone());
  }

  void setWorkspace(WorkspaceState workspace) {
    if (workspace == state.workspace) return;
    _commit(state.withWorkspace(workspace));
  }

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
    final account = _account(id);
    // The key is good for the endpoint as configured this moment: record
    // its origin first, so a later endpoint change stops sending it. The
    // binding before the secret: a write that fails half-way leaves a
    // binding without a key (a plain "no key"), never a key that can
    // never be sent.
    final config = ref.read(settingsProvider).provider(id)!;
    final origin = config.origin;
    if (origin != null && config.credentialOrigin != origin) {
      ref
          .read(settingsProvider.notifier)
          .upsertProvider(config.copyWith(credentialOrigin: () => origin));
    }
    ref.read(secretStoreProvider).write(account, value);
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

class SelectedTask extends Notifier<TaskId?> {
  @override
  TaskId? build() => null;

  void select(TaskId task) => state = task;

  void clear() => state = null;
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

  void set(bool shown) => state = shown;
}

/// The areas whose projects the sidebar folds away (#76). Compared by
/// content on every change, so re-applying the same set wakes nobody.
class CollapsedAreas extends Notifier<Set<AreaId>> {
  @override
  Set<AreaId> build() => const {};

  void toggle(AreaId area) => _apply({
    for (final id in state)
      if (id != area) id,
    if (!state.contains(area)) area,
  });

  void set(Iterable<AreaId> areas) => _apply({...areas});

  void _apply(Set<AreaId> next) {
    if (next.length == state.length && next.every(state.contains)) return;
    state = Set.unmodifiable(next);
  }
}

class ThingsImportNotifier extends Notifier<ThingsImportState> {
  /// Which attempt the state belongs to; a completion from an older one
  /// is dropped. [_busy] holds a second call while one is running.
  var _epoch = 0;
  var _busy = false;

  /// The snapshot the preview read, written by [run] as previewed.
  ThingsSnapshot? _snapshot;
  String? _snapshotPath;

  /// Progress is shown every so many operations: each one is a locked,
  /// synced append, and a rebuild per line would cost more than the line.
  static const progressEvery = 25;

  @override
  ThingsImportState build() => const ImportIdle();

  /// Finds the database under the group container, or the one
  /// [thingsDatabaseEnv] names. Runs only on request, never on build.
  void locate() {
    if (_busy) return;
    final environment = ref.read(environmentProvider);
    try {
      final path = locateThingsDatabase(
        environment: environment,
        home: environment['HOME'] ?? '',
      );
      state = path == null
          ? const ImportFailed(ThingsNotFound())
          : ImportSource(path);
    } on Object catch (error) {
      state = ImportFailed(classifyThingsError(error));
    }
  }

  /// Names the database by hand.
  void useDatabase(String path) {
    if (_busy) return;
    _snapshot = null;
    state = ImportSource(path);
  }

  /// Reads the database and plans a run with [options], writing nothing.
  Future<void> preview(ThingsImportOptions options) async {
    final path = switch (state) {
      ImportSource(:final path) ||
      ImportPlanned(:final path) ||
      ImportDone(:final path) => path,
      ImportFailed(:final path?) => path,
      _ => null,
    };
    if (path == null) {
      throw StateError('nothing to preview: choose a database first');
    }
    if (_busy) return;
    _busy = true;
    final epoch = ++_epoch;
    state = ImportReading(path);
    try {
      final snapshot = _snapshotPath == path && _snapshot != null
          ? _snapshot!
          : await ref.read(thingsSnapshotReaderProvider)(path);
      await ref.read(tasksProvider.future);
      if (epoch != _epoch) return;
      final store = ref.read(tasksProvider.notifier).store;
      final result = await importThings(
        snapshot,
        store: store,
        now: ref.read(clockProvider)().toUtc(),
        dryRun: true,
        options: options,
      );
      if (epoch != _epoch) return;
      _snapshot = snapshot;
      _snapshotPath = path;
      state = ImportPlanned(
        path: path,
        report: result.report,
        operations: result.plan.length,
        options: options,
      );
    } on Object catch (error) {
      if (epoch != _epoch) return;
      _snapshot = null;
      state = ImportFailed(classifyThingsError(error, path: path), path: path);
    } finally {
      if (epoch == _epoch) _busy = false;
    }
  }

  /// Writes what the preview planned. Nothing is re-read: what was shown
  /// is what lands.
  Future<void> run() async {
    if (_busy) return;
    final planned = state;
    if (planned is! ImportPlanned || _snapshot == null) {
      throw StateError('nothing to run: preview first');
    }
    _busy = true;
    final epoch = ++_epoch;
    final path = planned.path;
    final total = planned.operations;
    state = ImportRunning(path: path, done: 0, total: total);
    try {
      final store = ref.read(tasksProvider.notifier).store;
      final result = await importThings(
        _snapshot!,
        store: store,
        now: ref.read(clockProvider)().toUtc(),
        options: planned.options,
        onProgress: (done, total) {
          if (epoch != _epoch) return;
          if (done % progressEvery == 0 || done == total) {
            state = ImportRunning(path: path, done: done, total: total);
          }
        },
      );
      if (epoch != _epoch) return;
      state = ImportDone(
        path: path,
        report: result.report,
        operations: result.plan.length,
        eventsAppended: result.eventsAppended,
      );
    } on Object catch (error) {
      if (epoch != _epoch) return;
      state = ImportFailed(classifyThingsError(error, path: path), path: path);
    } finally {
      if (epoch == _epoch) _busy = false;
    }
  }

  /// Back to nothing; a step still running finishes into the void.
  void reset() {
    _epoch++;
    _busy = false;
    _snapshot = null;
    state = const ImportIdle();
  }
}

class ArchiveVerify extends Notifier<VerifyState> {
  var _running = false;

  @override
  VerifyState build() => const VerifyIdle();

  /// Walks the whole log. One walk at a time; a second call while one
  /// runs is ignored.
  Future<void> verify() async {
    if (_running) return;
    _running = true;
    state = const VerifyRunning();
    try {
      final archive = await ref.read(archiveProvider.future);
      final report = await archive.verify();
      state = Verified(report.count);
    } on Object catch (error) {
      state = VerifyFailed(_describe(error));
    } finally {
      _running = false;
    }
  }

  /// The reason and the file's name — never its full path, never a
  /// line's content.
  static String _describe(Object error) => switch (error) {
    ArchiveCorruptionError(:final reason, :final file, :final line) =>
      file == null
          ? reason
          : '$reason (${_basename(file)}${line == null ? '' : ':$line'})',
    TornTailError(:final file, :final offset) =>
      'a torn tail at byte $offset of ${_basename(file)}; truncate the '
          'file to that offset and verify again',
    _ => '$error',
  };

  static String _basename(String path) =>
      path.substring(path.lastIndexOf('/') + 1);
}

class Connection extends Notifier<ConnectionStatus> {
  /// How often a probeable provider is asked again.
  static const probeEvery = Duration(seconds: 60);

  Timer? _timer;
  LlmEndpointProbe? _probe;

  /// Which selection a probe answer belongs to; an older one is dropped.
  var _epoch = 0;

  /// Which probe is the newest; an older one still in flight is dropped
  /// too, so a slow "unavailable" cannot overwrite a fresh "ready".
  var _request = 0;

  @override
  ConnectionStatus build() {
    _timer?.cancel();
    _timer = null;
    _probe = null;
    final epoch = ++_epoch;
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
      _epoch++;
    });
    final settings = ref.watch(settingsProvider);
    if (settings.problem != null) {
      return const ConnectionStatus.down('settings unreadable');
    }
    final id = settings.llm;
    if (id == null) return const ConnectionStatus.down('no provider');
    final active = ref.watch(activeLlmProvider);
    if (active == null) {
      final missing = ref.watch(misconfiguredLlmsProvider)[id];
      return ConnectionStatus.down(
        missing == null ? 'not available' : 'misconfigured',
      );
    }
    switch (ref.watch(credentialStatusProvider(id))) {
      case CredentialStatus.missing:
        return const ConnectionStatus.down('no key');
      case CredentialStatus.unavailable:
        return const ConnectionStatus.down('keychain unavailable');
      case CredentialStatus.none || CredentialStatus.set:
        break;
    }
    if (active case final LlmEndpointProbe probe) {
      _probe = probe;
      scheduleMicrotask(() => _ask(epoch));
      if (ref.watch(connectionProbeEveryProvider) case final every?) {
        _timer = Timer.periodic(every, (_) => _ask(epoch));
      }
      return const ConnectionStatus.attention('probing…');
    }
    return const ConnectionStatus.ready('ready');
  }

  /// Asks the endpoint again now.
  void refresh() {
    if (_probe == null) return;
    state = const ConnectionStatus.attention('probing…');
    _ask(_epoch);
  }

  /// A call ended in [failure]: re-probe now rather than on the timer,
  /// so the light shows what the person just saw.
  void callFailed(LlmFailure failure) {
    switch (failure.kind) {
      case LlmFailureKind.unreachable ||
          LlmFailureKind.timeout ||
          LlmFailureKind.rejected ||
          LlmFailureKind.credential ||
          LlmFailureKind.protocol:
        refresh();
      case LlmFailureKind.internal || LlmFailureKind.archive:
        break;
    }
  }

  Future<void> _ask(int epoch) async {
    final probe = _probe;
    if (probe == null) return;
    final request = ++_request;
    EndpointInfo info;
    try {
      info = await probe.probe();
    } on Object catch (error) {
      // The contract says it never throws; if it does, that is "down".
      info = EndpointInfo(
        health: EndpointHealth.unavailable,
        failure: LlmFailure(LlmFailureKind.internal, '$error'),
      );
    }
    if (epoch != _epoch || request != _request || !ref.mounted) return;
    state = switch (info.health) {
      EndpointHealth.ok => const ConnectionStatus.ready('ready'),
      EndpointHealth.loading => const ConnectionStatus.attention('loading'),
      EndpointHealth.unavailable => ConnectionStatus.down(
        info.failure?.kind.name ?? 'unavailable',
      ),
      EndpointHealth.unknown => const ConnectionStatus.ready('ready'),
    };
  }
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
    final archiveFuture = ref.watch(archiveProvider.future);
    final source = ref.watch(eventSourceProvider);
    final openStore = ref.watch(taskStoreOpenerProvider);
    TaskStore? ownedStore;
    StreamSubscription<TaskProjection>? subscription;
    ref.onDispose(() {
      subscription?.cancel();
      ownedStore?.dispose();
      if (identical(_store, ownedStore)) {
        _store = null;
      }
    });

    final archive = await archiveFuture;
    final store = await openStore(archive, source: source);
    if (!ref.mounted) {
      store.dispose();
      return store.projection;
    }

    ownedStore = store;
    _store = store;
    subscription = store.changes.listen(
      (projection) => state = AsyncData(projection),
    );
    return store.projection;
  }

  /// Replays the log again so appends made by another process become
  /// visible ([TaskStore.reload]); the new projection lands in the state
  /// through the same change stream as a command. Throws the [store]'s
  /// [StateError] until [build] has settled.
  Future<void> reload() => store.reload();
}
