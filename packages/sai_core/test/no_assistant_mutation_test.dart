import 'dart:io';

import 'package:test/test.dart';

import 'package_root.dart';

/// The assistant never mutates the list by any path but an accepted
/// proposal (#35). Two mechanical guards: the assistant attribution is
/// spelled only where the definition lives and where accepts apply, and
/// the model-facing layers cannot even reach the store.
void main() {
  late Directory root;

  setUpAll(() async => root = await packageRoot());

  List<File> dartFiles(String under) =>
      Directory('${root.path}/$under')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();

  test('Attribution.assistant is spelled in exactly two lib files', () {
    final offenders = dartFiles('lib')
        .where((f) => f.readAsStringSync().contains('Attribution.assistant('))
        .map((f) => f.path.substring(root.path.length + 1))
        .toSet();
    expect(offenders, {
      // The definition and its guards.
      'lib/src/tasks/events.dart',
      // The one production caller: applying an accepted suggestion.
      'lib/src/proposals/apply.dart',
    });
  });

  test('chat, llm and context never import the task store', () {
    for (final layer in ['lib/src/chat', 'lib/src/llm', 'lib/src/context']) {
      final offenders = dartFiles(layer)
          .where((f) => f.readAsStringSync().contains('tasks/store.dart'))
          .map((f) => f.path)
          .toList();
      expect(offenders, isEmpty, reason: '$layer must not reach the store');
    }
  });
}
