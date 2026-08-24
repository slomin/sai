import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'app_info.dart';
import 'archive/archive.dart';
import 'archive/archive_root.dart';
import 'archive/event.dart';
import 'tasks/date.dart';
import 'tasks/projection.dart';
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
