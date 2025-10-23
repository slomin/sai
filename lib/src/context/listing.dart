import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

class DirectoryEntry {
  DirectoryEntry({
    required this.name,
    required this.isDir,
  });

  final String name;
  final bool isDir;
}

class DirectorySnapshot {
  DirectorySnapshot({
    required this.entries,
    required this.truncated,
    this.error,
  });

  final List<DirectoryEntry> entries;
  final bool truncated;
  final String? error;
}

DirectorySnapshot collectDirectorySnapshot({
  Directory? directory,
  List<String> ignorePatterns = const [],
  int maxEntries = 5000,
}) {
  final dir = directory ?? Directory.current;
  final entries = <DirectoryEntry>[];
  final ignoreGlobs = ignorePatterns.map((pattern) {
    return Glob(pattern, recursive: true);
  }).toList(growable: false);

  try {
    final listed = dir
        .listSync(followLinks: false)
        .where((entity) => !_isHidden(entity))
        .toList();
    listed.sort(
      (a, b) => p.basename(a.path).toLowerCase().compareTo(
            p.basename(b.path).toLowerCase(),
          ),
    );

    var truncated = false;
    for (final entity in listed) {
      final relative = p.relative(entity.path, from: dir.path);
      if (_matchesIgnore(relative, ignoreGlobs)) {
        continue;
      }
      entries.add(
        DirectoryEntry(
          name: p.basename(entity.path),
          isDir: entity is Directory,
        ),
      );
      if (entries.length >= maxEntries) {
        truncated = true;
        break;
      }
    }
    return DirectorySnapshot(
      entries: entries,
      truncated: truncated,
    );
  } on IOException catch (err) {
    return DirectorySnapshot(
      entries: const [],
      truncated: false,
      error: err.toString(),
    );
  }
}

bool _isHidden(FileSystemEntity entity) {
  final name = p.basename(entity.path);
  return name.startsWith('.');
}

bool _matchesIgnore(String candidate, List<Glob> globs) {
  for (final glob in globs) {
    if (glob.matches(candidate)) {
      return true;
    }
  }
  return false;
}
