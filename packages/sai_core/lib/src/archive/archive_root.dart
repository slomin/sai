import 'dart:io';

import 'package:path/path.dart' as p;

/// Where the archive lives when nothing says otherwise. Resolution order:
///
/// 1. `SAI_ARCHIVE_ROOT` — explicit override, used verbatim.
/// 2. macOS: `~/Library/Application Support/sai/archive` (ADR 0001 keeps
///    sai's data there so nothing needs a TCC grant).
/// 3. elsewhere: `$XDG_DATA_HOME/sai/archive`, or `~/.local/share/sai/archive`.
///
/// The default is deliberately outside any repository: the archive is a
/// life-long record, not a build artifact.
Directory resolveArchiveRoot({
  required Map<String, String> environment,
  required String operatingSystem,
}) {
  final override = environment['SAI_ARCHIVE_ROOT'];
  if (override != null && override.isNotEmpty) {
    return Directory(override);
  }
  final home = environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError(
      'cannot resolve the archive root: no SAI_ARCHIVE_ROOT and no HOME',
    );
  }
  if (operatingSystem == 'macos') {
    return Directory(
      p.join(home, 'Library', 'Application Support', 'sai', 'archive'),
    );
  }
  final dataHome = environment['XDG_DATA_HOME'];
  final base = (dataHome == null || dataHome.isEmpty)
      ? p.join(home, '.local', 'share')
      : dataHome;
  return Directory(p.join(base, 'sai', 'archive'));
}
