import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'app_info.dart';
import 'archive/archive.dart';
import 'archive/archive_root.dart';
import 'archive/event.dart';
import 'llm/fake.dart';
import 'llm/provider.dart';
import 'llm/recorder.dart';
import 'llm/status.dart';
import 'settings/settings.dart';
import 'settings/store.dart';
import 'tasks/date.dart';
import 'tasks/lists.dart';
import 'tasks/projection.dart';
import 'tasks/sidebar.dart';
import 'tasks/store.dart';

/// The application identity every client shows.
final appInfoProvider = Provider<AppInfo>(
  (ref) => const AppInfo(name: 'sai', version: saiVersion),
);

/// The line an empty shell shows until there is something to show.
final shellGreetingProvider = Provider<String>((ref) {
  final info = ref.watch(appInfoProvider);
  return '$info — nothing here yet';
});

/// The directory holding the event log. Tests and tools override this;
/// everyone else gets the platform default, which lives outside any repo.
final archiveRootProvider = Provider<Directory>(
  (ref) => resolveArchiveRoot(
    environment: Platform.environment,
    operatingSystem: Platform.operatingSystem,
  ),
);

/// The opened archive. Every client appends and reads through this single
/// instance; there is no other write path to the log. Disposal releases
/// the archive's lock handle so rebuilt providers never leak descriptors.
final archiveProvider = FutureProvider<Archive>((ref) async {
  final archive = await Archive.open(ref.watch(archiveRootProvider));
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

/// Today as a local calendar day. Computed once per provider lifetime — a
/// midnight rollover does not refresh it; the list views (#20) own that.
final todayProvider = Provider<CalendarDate>(
  (ref) => CalendarDate.fromLocal(ref.watch(clockProvider)()),
);

/// The task store and its projection, replayed from the archive. Read the
/// state for the current [TaskProjection]; use [TasksNotifier.store] for
/// commands — every mutation goes through it and lands here.
final tasksProvider = AsyncNotifierProvider<TasksNotifier, TaskProjection>(
  TasksNotifier.new,
);

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

/// The settings file (ADR 0006), beside the archive root — so a test or
/// tool that overrides [archiveRootProvider] gets its own settings too.
final settingsFileProvider = Provider<File>(
  (ref) => resolveSettingsFile(
    environment: Platform.environment,
    archiveRoot: ref.watch(archiveRootProvider),
  ),
);

/// Non-secret settings, read at first use and written on every change.
/// Use [SettingsNotifier.selectLlm] to switch the active provider.
final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(
  SettingsNotifier.new,
);

/// Every [LlmProvider] this build can offer, before validation. The fake
/// ships so offline development needs no credentials; #22 adds the
/// configured OpenAI-compatible endpoints.
final installedLlmsProvider = Provider<List<LlmProvider>>(
  (ref) => [FakeLlmProvider()],
);

/// The installed providers by id. Throws [StateError] on a duplicate id
/// at first read; closes the providers when disposed.
final llmRegistryProvider = Provider<Map<String, LlmProvider>>((ref) {
  final registry = <String, LlmProvider>{};
  for (final provider in ref.watch(installedLlmsProvider)) {
    if (registry.containsKey(provider.id)) {
      throw StateError('two LLM providers share the id "${provider.id}"');
    }
    registry[provider.id] = provider;
  }
  ref.onDispose(() {
    for (final provider in registry.values) {
      provider.close();
    }
  });
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
  if (active == null) return missingProviderStatus(id);
  return llmStatusLine(active);
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

/// Loads the settings file once and writes it on every change.
class SettingsNotifier extends Notifier<Settings> {
  SettingsStore get _store => SettingsStore(
    ref.read(settingsFileProvider),
    clock: ref.read(clockProvider),
  );

  late SettingsStore _opened;

  @override
  Settings build() {
    _opened = _store;
    return _opened.load();
  }

  /// Selects the provider with [id] (null for none), writing the file
  /// before the state changes. Throws [StateError] when the file belongs
  /// to a newer sai and must not be overwritten.
  void selectLlm(String? id) {
    final next = state.withLlm(id);
    _opened.save(next);
    state = next;
  }
}

class SelectedSection extends Notifier<SidebarSection> {
  @override
  SidebarSection build() => const ListSection(TaskList.today);

  void select(SidebarSection section) => state = section;
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
