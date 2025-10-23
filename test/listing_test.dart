import 'dart:io';

import 'package:sai/src/context/listing.dart';
import 'package:test/test.dart';

void main() {
  test('collectDirectorySnapshot filters hidden files and respects ignore', () async {
    final tempDir = await Directory.systemTemp.createTemp('sai-listing');
    Directory('${tempDir.path}/.git').createSync();
    File('${tempDir.path}/visible.txt').writeAsStringSync('hello');
    Directory('${tempDir.path}/node_modules').createSync();

    final snapshot = collectDirectorySnapshot(
      directory: tempDir,
      ignorePatterns: const ['node_modules'],
      maxEntries: 10,
    );

    expect(snapshot.entries.map((e) => e.name), contains('visible.txt'));
    expect(snapshot.entries.map((e) => e.name), isNot(contains('.git')));
    expect(snapshot.entries.map((e) => e.name), isNot(contains('node_modules')));

    await tempDir.delete(recursive: true);
  });
}
