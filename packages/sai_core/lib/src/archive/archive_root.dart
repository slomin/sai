import 'dart:io';

import 'package:path/path.dart' as p;

import '../identity.dart';

/// Where the archive lives when nothing says otherwise. Resolution order:
///
/// 1. `SAI_ARCHIVE_ROOT` — explicit override, used verbatim.
/// 2. macOS: `~/Library/Application Support/sai/archive` (ADR 0001 keeps
///    sai's data there so nothing needs a TCC grant).
/// 3. elsewhere: `$XDG_DATA_HOME/sai/archive`, or `~/.local/share/sai/archive`.
///
/// The default is deliberately outside any repository: the archive is a
/// life-long record, not a build artifact. The dev flavor has its own
/// directory (`sai-dev`), so the two copies never read one log.
Directory resolveArchiveRoot({
  required Map<String, String> environment,
  required String operatingSystem,
  SaiIdentity identity = SaiIdentity.stable,
}) {
  final override = environment['SAI_ARCHIVE_ROOT'];
  if (override != null && override.isNotEmpty) {
    return Directory(override);
  }
  return Directory(
    p.join(
      resolveDataDir(
        environment: environment,
        operatingSystem: operatingSystem,
        identity: identity,
        what: 'the archive root: no SAI_ARCHIVE_ROOT',
      ).path,
      'archive',
    ),
  );
}

/// sai's data directory: `~/Library/Application Support/sai` on macOS,
/// `$XDG_DATA_HOME/sai` or `~/.local/share/sai` elsewhere — `sai-dev` for
/// the dev flavor. The default archive lives in it, and so does the
/// settings file (ADR 0006).
Directory resolveDataDir({
  required Map<String, String> environment,
  required String operatingSystem,
  SaiIdentity identity = SaiIdentity.stable,
  String what = 'the data directory',
}) {
  final home = environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError('cannot resolve $what and no HOME');
  }
  if (operatingSystem == 'macos') {
    return Directory(
      p.join(home, 'Library', 'Application Support', identity.dataDirName),
    );
  }
  final dataHome = environment['XDG_DATA_HOME'];
  final base = (dataHome == null || dataHome.isEmpty)
      ? p.join(home, '.local', 'share')
      : dataHome;
  return Directory(p.join(base, identity.dataDirName));
}
