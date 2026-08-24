import 'dart:io';

import 'package:path/path.dart' as p;

import 'settings.dart';

/// Where the settings file lives: `SAI_SETTINGS_FILE` when set, else
/// `settings.json` beside the archive directory — with the archive at
/// `<data>/archive`, settings are `<data>/settings.json` (ADR 0006).
File resolveSettingsFile({
  required Map<String, String> environment,
  required Directory archiveRoot,
}) {
  final override = environment['SAI_SETTINGS_FILE'];
  if (override != null && override.isNotEmpty) return File(override);
  return File(p.join(archiveRoot.parent.path, 'settings.json'));
}

/// Reads and writes the settings file. Synchronous: the file is a few
/// hundred bytes, and the callers are notifiers that must not flicker.
final class SettingsStore {
  SettingsStore(this.file, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.timestamp;

  final File file;
  final DateTime Function() _clock;
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
    try {
      return Settings.decode(file.readAsStringSync());
    } on NewerSettingsVersion catch (e) {
      _readOnly = true;
      return Settings(
        problem:
            '${p.basename(file.path)} is version ${e.version}, newer than '
            'this sai understands; it is left as it is',
      );
    } on SettingsFormatException catch (e) {
      final aside = _quarantine();
      return Settings(
        problem:
            '${p.basename(file.path)} was not readable (${e.reason}) and '
            'was moved aside as ${p.basename(aside.path)}',
      );
    }
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

  File _quarantine() {
    final ts = _clock().toUtc();
    String pad(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${ts.year}${pad(ts.month)}${pad(ts.day)}'
        'T${pad(ts.hour)}${pad(ts.minute)}${pad(ts.second)}Z';
    return file.renameSync('${file.path}.bad-$stamp');
  }
}
