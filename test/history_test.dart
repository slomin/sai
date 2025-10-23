import 'dart:io';

import 'package:sai/src/context/history.dart';
import 'package:test/test.dart';

void main() {
  test('parseHistoryLines trims numbering and limits entries', () {
    final raw = '  1  ls\n  2  git status\n  3  dart test\n';
    final parsed = parseHistoryLines(raw, limit: 2);
    expect(parsed, equals(const ['git status', 'dart test']));
  });

  test('loadHistoryFile returns history when file exists', () async {
    final tempDir = await Directory.systemTemp.createTemp('sai-test');
    final file = File('${tempDir.path}/history');
    await file.writeAsString('  1  ls\n  2 echo "hi"\n');

    final result = await loadHistoryFile(file.path, limit: 10);
    expect(result, equals(const ['ls', 'echo "hi"']));

    await tempDir.delete(recursive: true);
  });

  test('loadHistoryFile returns empty when file missing', () async {
    final result = await loadHistoryFile('nonexistent', limit: 10);
    expect(result, isEmpty);
  });
}
