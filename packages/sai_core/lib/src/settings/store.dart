import 'dart:io';

import 'package:path/path.dart' as p;

import '../archive/archive_root.dart';
import '../identity.dart';
import 'settings.dart';

/// Where the settings file lives: `SAI_SETTINGS_FILE` when set, else
/// `settings.json` in sai's data directory (ADR 0006). Independent of
/// `SAI_ARCHIVE_ROOT`: pointing the archive at a scratch directory does
/// not move the settings into whatever is next to it.
File resolveSettingsFile({
  required Map<String, String> environment,
  required String operatingSystem,
  SaiIdentity identity = SaiIdentity.stable,
}) {
  final override = environment['SAI_SETTINGS_FILE'];
  if (override != null && override.isNotEmpty) return File(override);
  final data = resolveDataDir(
    environment: environment,
    operatingSystem: operatingSystem,
    identity: identity,
    what: 'the settings file: no SAI_SETTINGS_FILE',
  );
  return File(p.join(data.path, 'settings.json'));
}

/// Reads and writes the settings file. Synchronous: the file is a few
/// hundred bytes, and the callers are notifiers that must not flicker.
final class SettingsStore {
  SettingsStore(this.file, {DateTime Function()? clock, this.beforeQuarantine})
    : _clock = clock ?? DateTime.timestamp;

  final File file;
  final DateTime Function() _clock;

  /// Test seam: runs between deciding to quarantine and the rename.
  final void Function()? beforeQuarantine;
  bool _readOnly = false;

  /// The per-process temp file a write goes through. No lock guards the
  /// settings, so the name carries the pid: two clients writing at once
  /// cannot clobber each other's temp, and the rename is last-write-wins.
  File get tempFile => File('${file.path}.$pid.tmp');

  /// Loads the settings. A missing file is [Settings.empty] and nothing
  /// is written. Unparseable content is moved aside as
  /// `settings.json.bad-<ts>` and reported through [Settings.problem].
  /// A newer version is reported, left untouched, and makes this store
  /// refuse to [save] — a newer sai's settings are never overwritten.
  Settings load() {
    if (!file.existsSync()) return Settings.empty;
    final name = p.basename(file.path);
    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException catch (e) {
      // Not UTF-8 is content, and gets quarantined; anything else (a
      // permission, a race with a delete) is reported and left alone.
      if (e.osError == null) return _quarantined(name, e.message);
      return Settings(problem: '$name could not be read: ${e.message}');
    }
    try {
      return Settings.decode(text);
    } on NewerSettingsVersion catch (e) {
      _readOnly = true;
      return Settings(
        problem:
            '$name is version ${e.version}, newer than this sai '
            'understands; it is left as it is',
      );
    } on SettingsFormatException catch (e) {
      return _quarantined(name, e.reason);
    }
  }

  Settings _quarantined(String name, String reason) {
    final File aside;
    try {
      aside = _quarantine();
    } on FileSystemException {
      // Another client moved it first, or it vanished: nothing to keep.
      return Settings(problem: '$name was not readable ($reason) and is gone');
    }
    return Settings(
      problem:
          '$name was not readable ($reason) and was moved aside as '
          '${p.basename(aside.path)}',
    );
  }

  /// Writes [settings] atomically: temp file, fsync, rename.
  ///
  /// Throws [StateError] when [load] found a newer version.
  void save(Settings settings) {
    if (_readOnly) {
      throw StateError(
        '${file.path} was written by a newer sai and is not overwritten',
      );
    }
    file.parent.createSync(recursive: true);
    final temp = tempFile;
    final raf = temp.openSync(mode: FileMode.writeOnly);
    try {
      raf.writeStringSync(settings.encode());
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
    temp.renameSync(file.path);
  }

  /// Moves the file aside under a microsecond stamp; a name already
  /// taken (a pinned clock, two edits in one tick) gets a counter, so a
  /// quarantine never overwrites an earlier one.
  File _quarantine() {
    beforeQuarantine?.call();
    final ts = _clock().toUtc();
    String pad(int n, [int width = 2]) => n.toString().padLeft(width, '0');
    final stamp =
        '${ts.year}${pad(ts.month)}${pad(ts.day)}'
        'T${pad(ts.hour)}${pad(ts.minute)}${pad(ts.second)}'
        '${pad(ts.millisecond * 1000 + ts.microsecond, 6)}Z';
    var target = '${file.path}.bad-$stamp';
    for (var n = 1; File(target).existsSync(); n++) {
      target = '${file.path}.bad-$stamp-$n';
    }
    return file.renameSync(target);
  }
}
