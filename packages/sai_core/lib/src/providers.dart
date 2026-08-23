import 'dart:io';

import 'package:riverpod/riverpod.dart';

import 'app_info.dart';
import 'archive/archive.dart';
import 'archive/archive_root.dart';

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
/// instance; there is no other write path to the log.
final archiveProvider = FutureProvider<Archive>(
  (ref) => Archive.open(ref.watch(archiveRootProvider)),
);
