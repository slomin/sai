import 'dart:convert';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  const full = WorkspaceState(
    section: 'project:sha256-aa',
    task: 'sha256-bb',
    collapsedAreas: ['sha256-cc', 'sha256-dd'],
    assistantVisible: false,
  );

  group('WorkspaceState', () {
    test('round-trips through settings, keys sorted', () {
      final text = Settings.empty.withWorkspace(full).encode();
      expect(
        text,
        '{"llm":null,"version":0,"workspace":{"assistant_visible":false,'
        '"collapsed_areas":["sha256-cc","sha256-dd"],'
        '"section":"project:sha256-aa","task":"sha256-bb"}}',
      );
      expect(Settings.decode(text).workspace, full);
      expect(Settings.decode(text).problem, isNull);
    });

    test('is omitted while empty, so an untouched file stays byte-exact', () {
      expect(WorkspaceState.empty.isEmpty, isTrue);
      expect(Settings.empty.encode(), '{"llm":null,"version":0}');
      expect(
        Settings.empty
            .withWorkspace(full)
            .withWorkspace(WorkspaceState.empty)
            .encode(),
        '{"llm":null,"version":0}',
      );
      expect(Settings.decode('{"version":0}').workspace, WorkspaceState.empty);
      final only = const WorkspaceState(assistantVisible: true);
      expect(
        Settings.empty.withWorkspace(only).encode(),
        '{"llm":null,"version":0,"workspace":{"assistant_visible":true}}',
      );
    });

    test('a malformed workspace is dropped, never a reason to refuse', () {
      for (final (bad, expected) in <(String, WorkspaceState)>[
        ('5', WorkspaceState.empty),
        ('"today"', WorkspaceState.empty),
        ('[]', WorkspaceState.empty),
        ('null', WorkspaceState.empty),
        ('{}', WorkspaceState.empty),
        ('{"section":7}', WorkspaceState.empty),
        ('{"section":""}', WorkspaceState.empty),
        ('{"task":["x"]}', WorkspaceState.empty),
        ('{"collapsed_areas":"a"}', WorkspaceState.empty),
        (
          '{"collapsed_areas":["a",1,null,"b"]}',
          const WorkspaceState(collapsedAreas: ['a', 'b']),
        ),
        ('{"assistant_visible":"no"}', WorkspaceState.empty),
        (
          '{"section":"list:today","later_key":{"x":1}}',
          const WorkspaceState(section: 'list:today'),
        ),
      ]) {
        final settings = Settings.decode(
          '{"version":0,"llm":"fake","workspace":$bad}',
        );
        expect(settings.workspace, expected, reason: bad);
        expect(settings.problem, isNull, reason: bad);
        expect(settings.llm, 'fake', reason: bad);
      }
    });

    test('a malformed workspace is rewritten clean on the next write', () {
      final settings = Settings.decode('{"version":0,"workspace":5}');
      expect(settings.withLlm('fake').encode(), '{"llm":"fake","version":0}');
    });

    test('every with* preserves the workspace', () {
      final settings = Settings.empty.withWorkspace(full);
      final config = ProviderConfig(id: 'x', kind: 'fake');
      expect(settings.withLlm('x').workspace, full);
      expect(settings.withReasoning(true).workspace, full);
      expect(settings.withShareTasksWithCloud(true).workspace, full);
      expect(settings.withProvider(config).workspace, full);
      expect(
        settings.withProvider(config).withoutProvider('x').workspace,
        full,
      );
    });

    test('a secret-looking member still refuses the file', () {
      expect(
        () => Settings.decode(
          '{"version":0,"workspace":{"section":"trash","token":"abc"}}',
        ),
        throwsA(isA<SettingsFormatException>()),
      );
    });

    test('compares by content', () {
      expect(full, full);
      expect(
        WorkspaceState.fromJson(jsonDecode(jsonEncode(full.toJson()))),
        full,
      );
      expect(full, isNot(const WorkspaceState(section: 'project:sha256-aa')));
      expect(
        const WorkspaceState(collapsedAreas: ['a', 'b']),
        isNot(const WorkspaceState(collapsedAreas: ['b', 'a'])),
      );
    });
  });
}
