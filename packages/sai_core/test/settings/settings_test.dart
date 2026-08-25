import 'dart:convert';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  group('Settings', () {
    test('empty settings select nothing', () {
      expect(Settings.empty.llm, isNull);
      expect(Settings.empty.problem, isNull);
      expect(Settings.empty.encode(), '{"llm":null,"version":0}');
    });

    test('round-trips the selection', () {
      final text = const Settings(llm: 'fake').encode();
      expect(jsonDecode(text), {'version': 0, 'llm': 'fake'});
      expect(Settings.decode(text).llm, 'fake');
      expect(Settings.decode('{"version":0}').llm, isNull);
      expect(Settings.decode('{"version":0,"llm":null}').llm, isNull);
    });

    test('unknown keys survive a round trip', () {
      final decoded = Settings.decode(
        '{"version":0,"llm":"fake","endpoints":[{"name":"lan"}]}',
      );
      final written = jsonDecode(decoded.withLlm(null).encode());
      expect(written, {
        'version': 0,
        'llm': null,
        'endpoints': [
          {'name': 'lan'},
        ],
      });
    });

    test('the cloud-sharing switch is off, unwritten, until set', () {
      expect(Settings.empty.shareTasksWithCloud, isFalse);
      expect(Settings.decode('{"version":0}').shareTasksWithCloud, isFalse);
      final on = Settings.empty.withShareTasksWithCloud(true);
      expect(
        on.encode(),
        '{"llm":null,"share_tasks_with_cloud":true,"version":0}',
      );
      expect(Settings.decode(on.encode()).shareTasksWithCloud, isTrue);
      expect(
        on.withShareTasksWithCloud(false).encode(),
        Settings.empty.encode(),
      );
      // Every copy keeps it.
      expect(on.withLlm('fake').shareTasksWithCloud, isTrue);
      expect(
        on
            .withProvider(ProviderConfig(id: 'a', kind: 'fake'))
            .shareTasksWithCloud,
        isTrue,
      );
      expect(on.withoutProvider('a').shareTasksWithCloud, isTrue);
      expect(
        () => Settings.decode('{"version":0,"share_tasks_with_cloud":"yes"}'),
        throwsA(
          isA<SettingsFormatException>().having(
            (e) => e.reason,
            'reason',
            'share_tasks_with_cloud must be a boolean',
          ),
        ),
      );
    });

    test('withLlm clears a stale problem', () {
      const broken = Settings(problem: 'was unreadable');
      expect(broken.withLlm('fake').problem, isNull);
    });

    test('malformed or mistyped content is a format error', () {
      for (final bad in [
        'not json',
        '[]',
        '{"llm":"fake"}',
        '{"version":"0"}',
        '{"version":0,"llm":3}',
        '{"version":0,"llm":""}',
      ]) {
        expect(
          () => Settings.decode(bad),
          throwsA(isA<SettingsFormatException>()),
          reason: bad,
        );
      }
    });

    test('a newer version is refused, distinctly', () {
      expect(
        () => Settings.decode('{"version":1,"llm":"x"}'),
        throwsA(
          isA<NewerSettingsVersion>().having((e) => e.version, 'version', 1),
        ),
      );
    });
  });
  group('reasoning', () {
    test('round-trips, is refused when not a boolean, and is omitted off', () {
      final on = Settings.decode('{"version":0,"reasoning":true}');
      expect(on.reasoningOn, isTrue);
      expect(on.encode(), '{"llm":null,"reasoning":true,"version":0}');
      expect(on.withReasoning(false).encode(), '{"llm":null,"version":0}');
      expect(Settings.decode('{"version":0}').reasoningOn, isFalse);
      expect(
        () => Settings.decode('{"version":0,"reasoning":1}'),
        throwsA(isA<SettingsFormatException>()),
      );
      // Every with* keeps it.
      expect(on.withLlm('x').reasoningOn, isTrue);
      expect(on.withShareTasksWithCloud(true).reasoningOn, isTrue);
      expect(on.withoutProvider('x').reasoningOn, isTrue);
    });
  });
}
