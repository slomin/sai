import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'app_info.dart';
import 'identity.dart';
import 'archive/archive.dart';
import 'chat/chat.dart';
import 'context/assemble.dart';
import 'archive/archive_root.dart';
import 'archive/event.dart';
import 'archive/verify_state.dart';
import 'llm/call.dart';
import 'llm/connection.dart';
import 'llm/effort.dart';
import 'llm/failure.dart';
import 'llm/builtins.dart';
import 'llm/factory.dart';
import 'llm/openai/openai.dart';
import 'llm/openai_compatible/policy.dart';
import 'llm/openai_compatible/provider.dart';
import 'llm/openrouter.dart';
import 'llm/privacy.dart';
import 'llm/probe.dart';
import 'llm/provider.dart';
import 'llm/recorder.dart';
import 'llm/status.dart';
import 'llm/usage.dart';
import 'proposals/notifier.dart';
import 'proposals/proposal.dart';
import 'secrets/keychain.dart';
import 'secrets/secret_store.dart';
import 'settings/provider_config.dart';
import 'settings/settings.dart';
import 'settings/store.dart';
import 'settings/workspace.dart';
import 'tasks/date.dart';
import 'tasks/follower.dart';
import 'tasks/lists.dart';
import 'tasks/model.dart';
import 'tasks/navigation.dart';
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
  (ref) => AppInfo(
    name: ref.watch(identityProvider).displayName,
    version: saiVersion,
  ),
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
  final visibility = ref.watch(finishedTaskVisibilityProvider);
  return ref
      .watch(tasksProvider)
      .whenData(
        (projection) =>
            taskView(projection, section, today: today, visibility: visibility),
      );
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

/// Daily usage totals (#30), folded from the log's `provider.usage`
/// lines and re-read for the same reasons as [archiveStatsProvider] —
/// the recorder is a writer the other watchers cannot see, so a
/// provider test bumps [archiveRevisionProvider].
final dailyUsageProvider = FutureProvider<UsageProjection>((ref) async {
  ref.watch(tasksProvider);
  ref.watch(chatProvider.select((s) => s.turns.length));
  ref.watch(archiveRevisionProvider);
  final archive = await ref.watch(archiveProvider.future);
  final events = <StoredEvent>[];
  for (var attempt = 0; ; attempt++) {
    events.clear();
    try {
      await for (final stored in archive.events()) {
        events.add(stored);
      }
      break;
    } on TornTailError {
      // A tear can be the transient shadow of an in-flight append; one
      // retry reads the settled tail (the task store does the same).
      if (attempt > 0) break;
    }
  }
  return UsageProjection.replay(events);
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

/// Keeps this process's projection in step with another sai process
/// writing to the same archive (#118): every [ArchiveFollower.pollEvery]
/// it asks the store whether the log holds lines this process did not
/// write ([TaskStore.hasForeignLines]) and replays only then. Nothing
/// rebuilds on it but the reload notice, so each client's shell watches
/// it to keep it alive for the process's life.
final archiveFollowerProvider =
    NotifierProvider<ArchiveFollower, FollowerState>(ArchiveFollower.new);

/// How often the follower looks — null never looks on a timer. Test
/// harnesses override it and drive [ArchiveFollower.tick] by hand.
final archivePollEveryProvider = Provider<Duration?>(
  (ref) => ArchiveFollower.pollEvery,
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

/// The reasoning effort the next request to the active provider carries
/// (#26): an OpenAI kind's own `reasoning_effort` setting — null for
/// Model default — or, for every other kind, the switch above translated
/// as it always was (on → the backend's default, off → `none`). Resolved
/// here, before assembly, so a client never decides a wire word.
final requestedEffortProvider = Provider<ReasoningEffort?>((ref) {
  final provider = ref.watch(activeLlmProvider);
  final on = ref.watch(reasoningProvider);
  if (provider == null) return on ? null : ReasoningEffort.none;
  return requestedEffortFor(provider, reasoningOn: on);
});

/// When a finished task leaves its working views (#97), as settings hold
/// it (`finished_task_visibility`, end of the local day by default).
final finishedTaskVisibilityProvider = Provider<FinishedTaskVisibility>(
  (ref) => ref.watch(settingsProvider.select((s) => s.finishedTaskVisibility)),
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

/// The propose/confirm lane (#35): the latest proposal and the person's
/// verdicts on its items. Session state; the archive keeps the record.
final proposalsProvider = NotifierProvider<ProposalsNotifier, ProposalsState>(
  ProposalsNotifier.new,
);

/// The lane as a client renders it: every item of the current proposal,
/// staleness derived against the live projection — so the app's watch
/// and the TUI's archive poll re-derive it for free.
final suggestionViewsProvider = Provider<List<SuggestionView>>((ref) {
  final proposal = ref.watch(proposalsProvider).current;
  if (proposal == null) return const [];
  final projection = ref.watch(tasksProvider).value;
  return List.unmodifiable([
    for (final item in proposal.items)
      SuggestionView(
        item: item,
        stale:
            item.status == SuggestionStatus.pending &&
            (projection == null || item.stale(projection)),
      ),
  ]);
});

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
/// flavor's service, memory anywhere else — and nowhere at all in the dev
/// flavor (#95), which has no service and opens no Keychain. Every test
/// harness overrides this with an [InMemorySecretStore] — nothing under
/// `test/` may reach the login keychain.
final secretStoreProvider = Provider<SecretStore>((ref) {
  final service = ref.watch(identityProvider).keychainService;
  if (service == null) return const NoSecretStore(devSecretsMessage);
  return Platform.isMacOS
      ? KeychainSecretStore(service: service)
      : InMemorySecretStore();
});

/// Whether a provider's credential is there. [CredentialStatus.none] is a
/// provider that takes no key; [CredentialStatus.absent] is the dev
/// flavor, which holds none (#95); the others say what the store answered.
enum CredentialStatus { none, set, missing, unavailable, absent }

/// Writes credentials through [secretStoreProvider] and bumps a revision
/// so [credentialStatusProvider] re-reads. Values never enter state.
final credentialsProvider = NotifierProvider<CredentialsNotifier, int>(
  CredentialsNotifier.new,
);

/// The credential status of the provider [id]: the account its
/// configuration names, or — for an unconfigured built-in that takes a
/// key (OpenRouter, #24) — the one it ships with. The fake, the local
/// built-ins and unknown ids take no key. Re-evaluated whenever
/// [credentialsProvider] writes or the configuration changes.
final credentialStatusProvider = Provider.family<CredentialStatus, String>((
  ref,
  id,
) {
  ref.watch(credentialsProvider);
  final account =
      ref.watch(settingsProvider.select((s) => s.provider(id)?.credential)) ??
      ref.watch(llmRegistryProvider.select((r) => _shippedCredential(r[id])));
  if (account == null) return CredentialStatus.none;
  if (ref.watch(identityProvider).keychainService == null) {
    return CredentialStatus.absent;
  }
  try {
    return ref.watch(secretStoreProvider).has(account)
        ? CredentialStatus.set
        : CredentialStatus.missing;
  } on SecretStoreException {
    return CredentialStatus.unavailable;
  }
});

/// The account an unconfigured built-in reads its key from, or null for
/// one that takes none or is not there.
String? _shippedCredential(LlmProvider? provider) =>
    provider is OpenAiCompatibleProvider ? provider.credential : null;

/// Where OpenRouter is (#24): the one fixed origin. Nothing in settings
/// or the environment reaches this; a test overrides it with a loopback
/// stub, and that is the only way the built-in or the factory ever talks
/// to anything else.
final openRouterEndpointProvider = Provider<Uri>((ref) => openRouterEndpoint);

/// Where the `openai` kind dials (#26): OpenAI's fixed origin, or the
/// loopback stub a test hands in — the factory refuses any other host.
final openAiEndpointProvider = Provider<Uri>((ref) => openAiEndpoint);

/// The factories this build can turn a [ProviderConfig] into, by kind.
final llmFactoriesProvider = Provider<Map<String, LlmProviderFactory>>((ref) {
  final openRouter = ref.watch(openRouterEndpointProvider);
  final openAi = ref.watch(openAiEndpointProvider);
  return {
    'fake': fakeProviderFactory,
    'openai_compatible': openAiCompatibleFactory,
    openRouterKind: (config, secrets) =>
        openRouterFactory(config, secrets, endpoint: openRouter),
    openAiKind: (config, secrets) =>
        openAiFactory(config, secrets, endpoint: openAi),
  };
});

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
      CredentialStatus.absent => absentCredentialSuffix,
    };

/// The providers that ship with every build, needing no configuration,
/// as constructors: the cache below decides when one is built. A
/// configured provider with the same id replaces the built-in one.
/// `llm/builtins.dart` lists them; the test harnesses override this with
/// the fake alone.
final builtinLlmsProvider = Provider<List<LlmProvider Function()>>(
  (ref) => builtinLlms(
    ref.watch(secretStoreProvider),
    fakeDelta: fakeDeltaFrom(ref.watch(environmentProvider)),
    openRouterEndpoint: ref.watch(openRouterEndpointProvider),
  ),
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
  final id = ref.watch(settingsProvider.select((s) => s.llm));
  if (id == null) return null;
  return ref.watch(llmRegistryProvider)[id];
});

/// Releases the idle sockets of the provider the selection moved away
/// from — to another, or to none — while the instance (and any running
/// call) lives on (#109). Its own dependency-free provider rather than
/// [Connection] state, so the listener outlives every [Connection]
/// rebuild; [Connection.build] keeps it alive for the session, exactly
/// like probing.
final _llmIdleReleaseProvider = Provider<void>((ref) {
  ref.listen(activeLlmProvider, (previous, next) {
    if (previous != null && !identical(previous, next)) {
      previous.releaseIdle();
    }
  });
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
  // Only what the line is made of: the workspace part of settings moves
  // with every click and must not redraw it.
  final (problem, id) = ref.watch(
    settingsProvider.select((s) => (s.problem, s.llm)),
  );
  if (problem != null) return unreadableSettingsStatus;
  if (id == null) return noProviderStatus;
  final active = ref.watch(activeLlmProvider);
  if (active == null) {
    final config = ref.watch(settingsProvider.select((s) => s.provider(id)));
    if (config == null) return missingProviderStatus(id);
    final missing = ref.watch(misconfiguredLlmsProvider)[id];
    if (missing != null) return misconfiguredStatus(id, missing);
    return unavailableKindStatus(id, config.kind);
  }
  return llmStatusLine(active, policy: ref.watch(privacyPolicyProvider)) +
      switch (ref.watch(credentialStatusProvider(id))) {
        CredentialStatus.missing => missingCredentialSuffix,
        CredentialStatus.unavailable => unavailableSecretsSuffix,
        CredentialStatus.absent => absentCredentialSuffix,
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

/// The context window each provider's endpoint last reported, by id
/// (#105). Retained across selection changes, but never past its own
/// truth: a healthy probe that reports no window clears the entry (the
/// endpoint does not say), and editing or removing a provider's config
/// clears it too — a re-pointed id must fall back to the conservative
/// default, not ride the old backend's number. Only a failed probe
/// leaves the last report standing. Fed by [Connection]'s probe and the
/// settings mutators — a send only reads, it never asks the network.
final contextWindowsProvider =
    NotifierProvider<ContextWindows, Map<String, int>>(ContextWindows.new);

class ContextWindows extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => const {};

  /// Records what [providerId]'s endpoint reported; null or nonsense
  /// keeps what stands.
  void report(String providerId, int? contextWindow) {
    if (contextWindow == null || contextWindow < 1) return;
    if (state[providerId] == contextWindow) return;
    state = Map.unmodifiable({...state, providerId: contextWindow});
  }

  /// Forgets [providerId]'s report — its endpoint said it has none, or
  /// its configuration changed under it.
  void clear(String providerId) {
    if (!state.containsKey(providerId)) return;
    state = Map.unmodifiable({...state}..remove(providerId));
  }
}

/// OpenRouter's zero-retention model list for the session (#112): read
/// on demand — the first time the app's OpenRouter block opens with a
/// key stored, and on Refresh — never on the probe's timer, never on a
/// task or chat change, never written anywhere. One reading at a time,
/// joined by every call made while it runs; a failed refresh keeps the
/// last list beside its failure; a key stored or removed forgets the
/// list, since it was read under another key. The container's lifetime
/// is the cache's: a restart forgets it.
final openRouterCatalogueProvider =
    NotifierProvider<OpenRouterCatalogueNotifier, OpenRouterCatalogue>(
      OpenRouterCatalogueNotifier.new,
    );

class OpenRouterCatalogueNotifier extends Notifier<OpenRouterCatalogue> {
  /// The reading under way, or null.
  Future<void>? _reading;

  /// Which forgetting the state belongs to: a reading that started
  /// before a [forget] lands nothing.
  var _epoch = 0;

  @override
  OpenRouterCatalogue build() {
    ref.listen(credentialsProvider, (_, _) => forget());
    return const OpenRouterCatalogue();
  }

  /// The reading under way, or nothing to wait for.
  Future<void> get done => _reading ?? Future.value();

  /// The session's first reading, through the OpenRouter provider [id]
  /// names — the built-in or a configured entry of that kind, whichever
  /// the block shows; nothing once one was attempted, however it went —
  /// Refresh is the retry.
  Future<void> load(String id) => state.attempted ? done : _read(id);

  /// A new reading through [id]. A call while one runs joins it: one
  /// request, one answer, and every caller waits for that answer.
  Future<void> refresh(String id) => _reading ?? _read(id);

  /// Drops what the session read (and any reading under way), so the
  /// next [load] reads again — or the block says a key is needed.
  void forget() {
    if (!state.attempted) return;
    _epoch++;
    _reading = null;
    state = const OpenRouterCatalogue();
  }

  /// Not at all when [id] is not an installed OpenRouter provider (a
  /// refused entry has none; the block's button is disabled then).
  Future<void> _read(String id) {
    final provider = ref.read(llmRegistryProvider)[id];
    if (provider is! OpenAiCompatibleProvider ||
        openRouterRoutingOf(provider) == null) {
      return Future.value();
    }
    final kept = state.models;
    state = OpenRouterCatalogue(models: kept, loading: true);
    late final Future<void> mine;
    mine = _fetch(provider, kept, _epoch).whenComplete(() {
      if (identical(_reading, mine)) _reading = null;
    });
    return _reading = mine;
  }

  Future<void> _fetch(
    OpenAiCompatibleProvider provider,
    List<String>? kept,
    int epoch,
  ) async {
    OpenRouterCatalogueAnswer answer;
    try {
      answer = await fetchOpenRouterCatalogue(provider);
    } on Object catch (error) {
      // The transport answers its own failures in fixed words; whatever
      // else can throw (a secret store of another kind) is still an
      // answer — never a reading left "under way" for the session.
      answer = (
        models: null,
        failure: LlmFailure(
          LlmFailureKind.internal,
          TransportText.threw(error),
          endpoint: provider.origin,
        ),
      );
    }
    if (!ref.mounted || epoch != _epoch) return;
    if (answer.failure != null && provider.isClosed) {
      // A settings edit rebuilt the provider under the reading and cut
      // its socket: nothing about the network, so nothing to show — the
      // block asks again through the provider that replaced it.
      state = OpenRouterCatalogue(models: kept);
      return;
    }
    state = OpenRouterCatalogue(
      models: answer.models ?? kept,
      failure: answer.failure,
    );
  }
}

/// Whether the cache warmer runs at all. Test harnesses switch it off
/// so a probeable provider in a widget test never fires an inference.
final warmEnabledProvider = Provider<bool>((ref) => true);

/// How long the catalog must sit unchanged before a warm is sent; null
/// disables scheduling.
final warmDebounceProvider = Provider<Duration?>(
  (ref) => const Duration(seconds: 5),
);

/// How often the warming fraction is re-estimated; null, no ticking.
final warmTickEveryProvider = Provider<Duration?>(
  (ref) => const Duration(seconds: 1),
);

/// Pre-warms a local endpoint's prompt cache (#105): whenever the
/// active provider is a reachable local endpoint and the catalog prefix
/// has changed, [assembleWarmup]'s one-token request goes through the
/// recorder in the background, so the minutes of prompt ingestion a
/// large collection costs on a laptop happen before the person asks —
/// the real turn then reuses the server's cached prefix and starts
/// fast. Held for the session by the clients' indicator widgets; the
/// CLI never activates it.
final cacheWarmerProvider = NotifierProvider<CacheWarmer, WarmState>(
  CacheWarmer.new,
);

class CacheWarmer extends Notifier<WarmState> {
  Timer? _debounce;
  Timer? _tick;
  RecordedCall? _call;
  var _epoch = 0;

  /// The prefix each provider id last warmed (catalog bytes and the
  /// reasoning effort), so an unchanged prefix is never re-sent.
  final _warmed = <String, (String, ReasoningEffort?)>{};

  /// The prefix each id last failed on — retried only once something
  /// changes, so a probe-ok-but-chat-failing endpoint cannot loop.
  final _failed = <String, (String, ReasoningEffort?)>{};

  /// Measured ingestion per id, in recorded request bytes per second,
  /// behind the indicator's percentage.
  final _rates = <String, double>{};

  LlmProvider? _lastProvider;

  /// The key of the warm now in flight, or null. A rebuild that wants
  /// the same key keeps the call running — the warm's own archive lines
  /// make the TUI re-read the log every two seconds, and cancelling on
  /// every content-identical projection turned one warm into a stutter
  /// of one-second bursts (measured before this guard existed).
  (String, ReasoningEffort?)? _inFlight;

  /// The last fraction shown, so the keep path can return it.
  double? _lastFraction;

  /// Abandons any scheduled or running warm and invalidates its
  /// continuations.
  void _stop() {
    _epoch++;
    _debounce?.cancel();
    _debounce = null;
    _tick?.cancel();
    _tick = null;
    _call?.cancel();
    _call = null;
    _inFlight = null;
  }

  @override
  WarmState build() {
    // Rescheduled below when still wanted; a pending timer must not
    // fire with stale inputs. No ref.onDispose here: a build-scoped
    // dispose hook fires on every rebuild, which is exactly the
    // cancel-everything the keep path below exists to avoid — the
    // continuations guard on [Ref.mounted] instead.
    _debounce?.cancel();
    _debounce = null;
    WarmState stopped() {
      _stop();
      return const WarmState(WarmPhase.idle);
    }

    if (!ref.watch(warmEnabledProvider)) return stopped();
    final provider = ref.watch(activeLlmProvider);
    if (provider == null ||
        provider.privacy != LlmPrivacy.local ||
        provider is! LlmEndpointProbe) {
      return stopped();
    }
    if (!identical(provider, _lastProvider)) {
      // A rebuilt provider is a changed configuration: its endpoint's
      // cache is not ours to assume.
      _warmed.remove(provider.id);
      _failed.remove(provider.id);
      _lastProvider = provider;
      _stop();
    }
    final projection = ref.watch(tasksProvider).value;
    if (projection == null) return stopped();
    final connection = ref.watch(connectionProvider);
    if (connection.level == ConnectionLevel.down) {
      // A down endpoint may have restarted; what it held is gone.
      _warmed.remove(provider.id);
      return stopped();
    }
    if (connection.level != ConnectionLevel.ready) return stopped();
    final effort = ref.watch(requestedEffortProvider);
    final request = assembleWarmup(
      profile: defaultProfile,
      projection: projection,
      today: ref.watch(todayProvider),
      reasoningEffort: effort,
    );
    final key = (request.taskContext!, effort);
    // A finished local catalog turn ingested this very prefix; note it
    // rather than re-sending 35 KB of request line after every answer.
    ref.listen(chatProvider, (previous, next) {
      if (previous == null || !previous.busy || next.busy) return;
      final last = next.turns.isEmpty ? null : next.turns.last;
      if (last != null &&
          last.role == ChatRole.assistant &&
          !last.failed &&
          last.provenance == TaskProvenance.catalog &&
          ref.mounted) {
        _warmed[provider.id] = key;
        state = const WarmState(WarmPhase.warm);
      }
    });
    if (ref.watch(chatProvider.select((s) => s.busy))) {
      // The slot belongs to the person's turn; the server keeps what a
      // cancelled warm already ingested — cancellation is client-side
      // only, by decision (ADR 0009, #109).
      return stopped();
    }
    if (_inFlight == key) {
      // The running warm is still the right one — let it finish.
      return WarmState(WarmPhase.warming, fraction: _lastFraction);
    }
    if (_inFlight != null) _stop();
    if (_warmed[provider.id] == key) return const WarmState(WarmPhase.warm);
    if (_failed[provider.id] == key) return const WarmState(WarmPhase.idle);
    final debounce = ref.watch(warmDebounceProvider);
    if (debounce == null) return const WarmState(WarmPhase.idle);
    final epoch = _epoch;
    _debounce = Timer(debounce, () => _warm(epoch, provider, request, key));
    return const WarmState(WarmPhase.idle);
  }

  Future<void> _warm(
    int epoch,
    LlmProvider provider,
    LlmRequest request,
    (String, ReasoningEffort?) key,
  ) async {
    if (epoch != _epoch || !ref.mounted) return;
    final container = ref.container;
    final bytes = recordedRequestBytes(request);
    final known = _rates[provider.id];
    final started = DateTime.now();
    _inFlight = key;
    _lastFraction = known == null ? null : 0;
    state = WarmState(WarmPhase.warming, fraction: _lastFraction);
    if (container.read(warmTickEveryProvider) case final every?) {
      _tick = Timer.periodic(every, (_) {
        if (!ref.mounted) {
          _tick?.cancel();
          return;
        }
        if (epoch != _epoch) return;
        final rate = _rates[provider.id];
        if (rate == null) return;
        final elapsed =
            DateTime.now().difference(started).inMilliseconds / 1000;
        _lastFraction = (elapsed * rate / bytes).clamp(0.0, 0.99);
        state = WarmState(WarmPhase.warming, fraction: _lastFraction);
      });
    }
    try {
      final recorder = await container.read(llmRecorderProvider.future);
      if (epoch != _epoch || !ref.mounted) return;
      final call = await recorder.start(provider, request);
      if (epoch != _epoch || !ref.mounted) {
        call.cancel();
        return;
      }
      _call = call;
      final result = await call.done;
      if (!ref.mounted) return;
      // The recorder just wrote lines no other watcher can see — the
      // same reason the Providers page bumps after its test (#30).
      container.read(archiveRevisionProvider.notifier).bump();
      if (epoch != _epoch) return;
      _tick?.cancel();
      _call = null;
      _inFlight = null;
      switch (result.finish) {
        case LlmFinish.failed:
          _failed[provider.id] = key;
          // The light learns of transport trouble as it does from a
          // failed turn.
          container
              .read(connectionProvider.notifier)
              .callFailed(result.failure!);
          state = const WarmState(WarmPhase.idle);
        case LlmFinish.cancelled:
          state = const WarmState(WarmPhase.idle);
        case LlmFinish.stop || LlmFinish.length:
          final seconds =
              DateTime.now().difference(started).inMilliseconds / 1000;
          if (seconds > 0.001) {
            final observed = bytes / seconds;
            final old = _rates[provider.id];
            _rates[provider.id] = old == null ? observed : (old + observed) / 2;
          }
          _warmed[provider.id] = key;
          state = const WarmState(WarmPhase.warm);
      }
    } on Object {
      // An unrecordable or refused warm is only a lost optimization.
      _failed[provider.id] = key;
      if (epoch == _epoch && ref.mounted) {
        _tick?.cancel();
        _inFlight = null;
        state = const WarmState(WarmPhase.idle);
      }
    }
  }
}

/// The budget the next chat turn is assembled for (#105): the active
/// local provider's last reported context window with the standing reply
/// reserve, else the conservative [defaultContextBudget]. Reading it
/// never awaits a probe — until the first probe answers, the default
/// applies. Cloud providers stay on the default: the compact context
/// has no use for a large window.
final chatBudgetProvider = Provider<ContextBudget>((ref) {
  final active = ref.watch(activeLlmProvider);
  if (active == null || active.privacy != LlmPrivacy.local) {
    return defaultContextBudget;
  }
  final window = ref.watch(contextWindowsProvider.select((w) => w[active.id]));
  return window == null
      ? defaultContextBudget
      : ContextBudget(
          maxTokens: window,
          replyReserve: defaultContextBudget.replyReserve,
        );
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

  /// Adds [config], or replaces the provider with its id in place. The
  /// id's reported context window is forgotten either way: a changed
  /// endpoint or model makes the old number another backend's (#105).
  void upsertProvider(ProviderConfig config) {
    ref.read(contextWindowsProvider.notifier).clear(config.id);
    _commit(state.withProvider(config));
  }

  /// Removes the provider [id], clearing its selection if it was active.
  /// The credential, if any, stays in the secret store — removing a
  /// configuration is not revoking a key; [CredentialsNotifier.clear]
  /// is.
  void removeProvider(String id) {
    ref.read(contextWindowsProvider.notifier).clear(id);
    _commit(state.withoutProvider(id));
  }

  /// Sets the cloud-sharing switch (#27).
  void setShareTasksWithCloud(bool share) =>
      _commit(state.withShareTasksWithCloud(share));

  void setReasoning(bool show) => _commit(state.withReasoning(show));

  /// Sets when a finished task leaves its working views (#97).
  void setFinishedTaskVisibility(FinishedTaskVisibility visibility) =>
      _commit(state.withFinishedTaskVisibility(visibility));

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

  /// Stores [value] under the account of the provider [id]
  /// (`provider:<id>` unless its configuration names another). A built-in
  /// that takes a key but is not configured yet (OpenRouter, #24) is
  /// configured as it ships first, so the entry naming the account is on
  /// disk before the secret is in the Keychain. Throws [StateError] for an
  /// unknown id or one that takes no key, and [SecretStoreException] when
  /// the store refuses.
  void set(String id, String value) {
    final config = ref.read(settingsProvider).provider(id);
    if (config == null) {
      // The key first, then the entry: the built-in reads the same
      // account, so a settings write that fails leaves a working
      // provider — never an entry the person did not confirm with no
      // key behind it. A refused Keychain write leaves nothing at all.
      final shipped = _shipped(id);
      if (shipped?.credential == null) throw _noCredential(id, shipped);
      ref.read(secretStoreProvider).write(shipped!.credential!, value);
      state++;
      ref.read(settingsProvider.notifier).upsertProvider(shipped);
      return;
    }
    final account = _account(id);
    // The key is good for the endpoint as configured this moment: record
    // its origin first, so a later endpoint change stops sending it. The
    // binding before the secret: a write that fails half-way leaves a
    // binding without a key (a plain "no key"), never a key that can
    // never be sent.
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
    if (ref.read(identityProvider).keychainService == null) {
      return CredentialStatus.absent;
    }
    try {
      return ref.read(secretStoreProvider).has(account)
          ? CredentialStatus.set
          : CredentialStatus.missing;
    } on SecretStoreException {
      return CredentialStatus.unavailable;
    }
  }

  /// The account of [id]: its configuration's, or the one an
  /// unconfigured built-in ships with.
  String _account(String id) {
    final config = ref.read(settingsProvider).provider(id) ?? _shipped(id);
    final account = config?.credential;
    if (account == null) throw _noCredential(id, config);
    return account;
  }

  /// The entry that would configure the built-in [id] as it ships, or
  /// null when no built-in has that id.
  ProviderConfig? _shipped(String id) {
    if (ref.read(settingsProvider).provider(id) != null) return null;
    final provider = ref.read(llmRegistryProvider)[id];
    return provider == null ? null : configFor(provider);
  }

  static StateError _noCredential(String id, ProviderConfig? config) =>
      StateError(
        config == null
            ? "provider '$id' is not configured"
            : "provider '$id' takes no credential",
      );
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
      state = VerifyFailed(_describeArchiveError(error));
    } finally {
      _running = false;
    }
  }
}

/// The reason and the file's name — never its full path, never a
/// line's content. What the verify (#40) and the follower (#118) show.
String _describeArchiveError(Object error) => switch (error) {
  ArchiveCorruptionError(:final reason, :final file, :final line) =>
    file == null
        ? reason
        : '$reason (${_basename(file)}${line == null ? '' : ':$line'})',
  TornTailError(:final file, :final offset) =>
    'a torn tail at byte $offset of ${_basename(file)}; truncate the '
        'file to that offset and verify again',
  _ => '$error',
};

String _basename(String path) => path.substring(path.lastIndexOf('/') + 1);

class Connection extends Notifier<ConnectionStatus> {
  /// How often a probeable provider is asked again.
  static const probeEvery = Duration(seconds: 60);

  Timer? _timer;
  LlmEndpointProbe? _probe;

  /// The selected provider's id while [_probe] is set — where a probe
  /// answer's context window is filed (#105).
  String? _id;

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
    _id = null;
    final epoch = ++_epoch;
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
      _epoch++;
    });
    // Selected, not the whole file: a workspace save (#76) must not turn
    // a ready connection amber and ask the endpoint again.
    final (problem, id) = ref.watch(
      settingsProvider.select((s) => (s.problem, s.llm)),
    );
    // Holds the release watcher for the session; and the active provider
    // is watched above the early returns, so even deselecting recomputes
    // it and the watcher sees the move.
    ref.watch(_llmIdleReleaseProvider);
    final active = ref.watch(activeLlmProvider);
    if (problem != null) {
      return const ConnectionStatus.down('settings unreadable');
    }
    if (id == null) return const ConnectionStatus.down('no provider');
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
      case CredentialStatus.absent:
        return const ConnectionStatus.down('no credentials in dev');
      case CredentialStatus.none || CredentialStatus.set:
        break;
    }
    if (active case final LlmEndpointProbe probe) {
      _probe = probe;
      _id = id;
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
    // The probe's other answer: what window the endpoint reports, kept
    // for the chat budget (#105). A healthy endpoint's word is final —
    // silence means it has no window to report, so a stale one from a
    // previous backend behind the same id is cleared. A failed probe
    // says nothing either way.
    if (_id case final id?) {
      final windows = ref.read(contextWindowsProvider.notifier);
      switch (info.health) {
        case EndpointHealth.ok || EndpointHealth.loading:
          if (info.contextWindow case final window?) {
            windows.report(id, window);
          } else {
            windows.clear(id);
          }
        case EndpointHealth.unavailable || EndpointHealth.unknown:
          break;
      }
    }
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

/// Owns the archive poll (#118). One check at a time; a check reads one
/// small file and reloads the store only when another process appended —
/// this process's own lines, whatever wrote them, are not news. The timer
/// belongs to the build that armed it and a late answer to a build that
/// is gone writes nothing, the way [Connection] scopes its probes.
class ArchiveFollower extends Notifier<FollowerState> {
  /// How often the head is checked when nothing overrides
  /// [archivePollEveryProvider]. A read of one tiny file.
  static const pollEvery = Duration(seconds: 2);

  Timer? _timer;
  Future<void>? _check;
  var _epoch = 0;

  /// The head count the last failure was seen at, when it could be
  /// read: the log is append-only, so the same lines would fail the same
  /// way — no retry until the log moves. A failure with no readable head
  /// (`HEAD` itself damaged) is retried each tick; that read is tiny and
  /// a restored file is how it recovers.
  int? _failedAt;

  @override
  FollowerState build() {
    _timer?.cancel();
    _timer = null;
    final epoch = ++_epoch;
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
      _epoch++;
    });
    if (ref.watch(archivePollEveryProvider) case final every?) {
      _timer = Timer.periodic(every, (_) => _tick(epoch));
    }
    return const FollowerState();
  }

  /// Looks now. A check already running is joined, not doubled.
  Future<void> tick() => _tick(_epoch);

  Future<void> _tick(int epoch) =>
      _check ??= _run(epoch).whenComplete(() => _check = null);

  Future<void> _run(int epoch) async {
    if (!ref.mounted) return;
    // Nothing to follow until the store is open; a store that failed to
    // open is the shell's error, not this notice.
    if (ref.read(tasksProvider).value == null) return;
    final tasks = ref.read(tasksProvider.notifier);
    final archive = await ref.read(archiveProvider.future);
    if (epoch != _epoch || !ref.mounted) return;
    try {
      final store = tasks.store;
      if (_failedAt != null && (await archive.head()).count == _failedAt) {
        return;
      }
      if (!await store.hasForeignLines()) {
        if (epoch == _epoch && ref.mounted && state.failure != null) {
          state = FollowerState(reloads: state.reloads);
        }
        return;
      }
      await tasks.reload();
      if (epoch != _epoch || !ref.mounted) return;
      _failedAt = null;
      state = FollowerState(reloads: state.reloads + 1);
    } on StateError {
      // The store changed under the check — a rebuild, a disposal: the
      // next tick finds the new one. Nothing to show.
      return;
    } on Object catch (error) {
      if (epoch != _epoch || !ref.mounted) return;
      _failedAt = await _headCountOrNull(archive);
      if (epoch != _epoch || !ref.mounted) return;
      state = FollowerState(
        reloads: state.reloads,
        failure: _describeArchiveError(error),
      );
    }
  }

  static Future<int?> _headCountOrNull(Archive archive) async {
    try {
      return (await archive.head()).count;
    } on Object {
      return null;
    }
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

/// Where the selected task stands in its view, or null while nothing is
/// selected or the selection has left the view.
final selectionIndexProvider = Provider<int?>((ref) {
  final selected = ref.watch(selectedTaskProvider);
  if (selected == null) return null;
  final section = ref.watch(selectedSectionProvider);
  final tasks = ref.watch(taskViewProvider(section)).value?.tasks;
  if (tasks == null) return null;
  final at = tasks.indexWhere((t) => t.id == selected);
  return at < 0 ? null : at;
});

/// The arrow keys in the workspace (#89). Which pane they move is read
/// off the screen rather than kept: a selected task means the list, none
/// means the sidebar. Its state is the last place the selection stood in
/// its view, so a task that has left the list — completed from Today —
/// is stepped from where it was. Keep it alive from launch (a client
/// listens to it), or the first click's place is not remembered.
final workspaceNavigatorProvider = NotifierProvider<WorkspaceNavigator, int?>(
  WorkspaceNavigator.new,
);

class WorkspaceNavigator extends Notifier<int?> {
  @override
  int? build() {
    ref.listen(selectionIndexProvider, (_, next) {
      if (next != null) state = next;
    });
    return ref.read(selectionIndexProvider);
  }

  void move(NavDirection direction) {
    final section = ref.read(selectedSectionProvider);
    final tasks =
        ref.read(taskViewProvider(section)).value?.tasks ?? const <Task>[];
    final selected = ref.read(selectedTaskProvider);
    if (selected != null) {
      _moveInList(tasks, selected, direction);
    } else {
      _moveInSidebar(section, tasks, direction);
    }
  }

  /// The row that takes the selection when [id] leaves the list: its
  /// neighbour, or — for a selection kept after its task was edited out
  /// of this list — the row standing where it stood.
  TaskId? successorOf(List<Task> tasks, TaskId id) {
    if (tasks.any((t) => t.id == id)) return neighbourOf(tasks, id);
    return stepTask(tasks, id, NavDirection.down, lastIndex: state);
  }

  void _moveInList(List<Task> tasks, TaskId selected, NavDirection direction) {
    final selection = ref.read(selectedTaskProvider.notifier);
    switch (direction) {
      case NavDirection.up || NavDirection.down:
        final next = stepTask(tasks, selected, direction, lastIndex: state);
        if (next != null) selection.select(next);
      case NavDirection.left:
        // Back to the sidebar row, which is where it was all along.
        selection.clear();
      case NavDirection.right:
        break;
    }
  }

  void _moveInSidebar(
    SidebarSection section,
    List<Task> tasks,
    NavDirection direction,
  ) {
    final model = ref.read(sidebarProvider).value;
    if (model == null) return;
    final collapsed = ref.read(collapsedAreasProvider);
    final fold = ref.read(collapsedAreasProvider.notifier);
    // Only a live area folds; the archived group draws its areas flat.
    final area = foldable(model, section)
        ? (section as AreaSection).area
        : null;
    switch (direction) {
      case NavDirection.up || NavDirection.down:
        final next = stepSection(model, collapsed, section, direction);
        if (next != null) {
          ref.read(selectedSectionProvider.notifier).select(next);
        }
      case NavDirection.right:
        if (area != null && collapsed.contains(area)) {
          fold.toggle(area);
          return;
        }
        final first = stepTask(tasks, null, direction);
        if (first != null) {
          ref.read(selectedTaskProvider.notifier).select(first);
        }
      case NavDirection.left:
        if (area != null && !collapsed.contains(area)) fold.toggle(area);
    }
  }
}
