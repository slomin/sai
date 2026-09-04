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
  group('the preference order', () {
    test('a single-id file reads as a one-entry order and writes back the '
        'same bytes', () {
      final one = Settings.decode('{"version":0,"llm":"lan"}');
      expect(one.llm, 'lan');
      expect(one.llmFallback, isEmpty);
      expect(one.llmOrder, ['lan']);
      expect(one.encode(), '{"llm":"lan","version":0}');
      expect(Settings.empty.llmOrder, isEmpty);
      expect(Settings.empty.encode(), '{"llm":null,"version":0}');
    });

    test('an order of several keeps its head in llm, so an older sai reads '
        'the first choice', () {
      final order = Settings.empty.withLlmOrder(['lan', 'local', 'openrouter']);
      expect(order.llm, 'lan');
      expect(order.llmFallback, ['local', 'openrouter']);
      expect(order.llmOrder, ['lan', 'local', 'openrouter']);
      final text = order.encode();
      expect(
        text,
        '{"llm":"lan","llm_fallback":["local","openrouter"],"version":0}',
      );
      // What an older sai sees: a plain string it selects, as before.
      expect(jsonDecode(text), containsPair('llm', 'lan'));
      expect(Settings.decode(text).llmOrder, ['lan', 'local', 'openrouter']);
    });

    test('withLlm sets the first entry, never the whole order', () {
      final order = Settings.empty.withLlmOrder(['a', 'b', 'c']);
      // Already in the order: moved to the front, nothing dropped.
      expect(order.withLlm('c').llmOrder, ['c', 'a', 'b']);
      expect(order.withLlm('a').llmOrder, ['a', 'b', 'c']);
      // New: it takes the head's place, and the arranged tail stands —
      // the order never grows out of what was used before.
      expect(order.withLlm('d').llmOrder, ['d', 'b', 'c']);
      expect(Settings.empty.withLlm('d').llmOrder, ['d']);
      expect(Settings.empty.withLlmOrder(['a']).withLlm('d').llmOrder, ['d']);
    });

    test('selecting none clears the whole order', () {
      final order = Settings.empty.withLlmOrder(['a', 'b']);
      final none = order.withLlm(null);
      expect(none.llm, isNull);
      expect(none.llmOrder, isEmpty);
      expect(none.encode(), '{"llm":null,"version":0}');
    });

    test('an order of one writes no tail', () {
      final one = Settings.empty.withLlmOrder(['a']);
      expect(one.encode(), '{"llm":"a","version":0}');
      expect(
        Settings.empty.withLlmOrder(const []).encode(),
        '{"llm":null,"version":0}',
      );
    });

    test('a removed provider leaves the order wherever it stood', () {
      final order = Settings.empty
          .withLlmOrder(['a', 'b', 'c'])
          .withProvider(ProviderConfig(id: 'b', kind: 'fake'));
      expect(order.withoutProvider('b').llmOrder, ['a', 'c']);
      // The head goes with it, and the next entry answers.
      expect(order.withoutProvider('a').llmOrder, ['b', 'c']);
      expect(order.withoutProvider('a').llm, 'b');
    });

    test('a tail entry that repeats the head, or itself, is dropped on read '
        'and not written again', () {
      final decoded = Settings.decode(
        '{"version":0,"llm":"a","llm_fallback":["b","a","b","c"]}',
      );
      expect(decoded.llmOrder, ['a', 'b', 'c']);
      expect(
        decoded.encode(),
        '{"llm":"a","llm_fallback":["b","c"],"version":0}',
      );
    });

    test('a tail without a head is nothing selected, as an older sai reads '
        'it', () {
      final decoded = Settings.decode(
        '{"version":0,"llm":null,"llm_fallback":["a","b"]}',
      );
      expect(decoded.llm, isNull);
      expect(decoded.llmOrder, isEmpty);
      expect(decoded.encode(), '{"llm":null,"version":0}');
    });

    test('an entry that is not a provider id is not an entry', () {
      // The order is one word with the ids joined by a space, which their
      // form cannot hold; anything else would split into phantoms.
      final decoded = Settings.decode(
        '{"version":0,"llm":"a b","llm_fallback":["c d","e","F"]}',
      );
      expect(decoded.llm, isNull);
      expect(decoded.llmOrder, isEmpty);
      expect(decoded.encode(), '{"llm":null,"version":0}');
      final kept = Settings.decode(
        '{"version":0,"llm":"a","llm_fallback":["b c","d"]}',
      );
      expect(kept.llmOrder, ['a', 'd']);
      expect(kept.llmOrderKey, 'a d');
    });

    test('a mistyped tail is a format error', () {
      for (final bad in [
        '{"version":0,"llm":"a","llm_fallback":"b"}',
        '{"version":0,"llm":"a","llm_fallback":{"1":"b"}}',
        '{"version":0,"llm":"a","llm_fallback":["b",3]}',
        '{"version":0,"llm":"a","llm_fallback":["b",""]}',
        '{"version":0,"llm":"a","llm_fallback":["b",null]}',
      ]) {
        expect(
          () => Settings.decode(bad),
          throwsA(
            isA<SettingsFormatException>().having(
              (e) => e.reason,
              'reason',
              'llm_fallback must be a list of non-empty strings',
            ),
          ),
          reason: bad,
        );
      }
    });

    test('the order key moves with the order and with nothing else', () {
      final order = Settings.empty.withLlmOrder(['a', 'b']);
      expect(order.llmOrderKey, 'a b');
      expect(Settings.empty.llmOrderKey, '');
      expect(
        order.withWorkspace(const WorkspaceState(task: 'x')).llmOrderKey,
        order.llmOrderKey,
      );
      expect(order.withShareTasksWithCloud(true).llmOrderKey, 'a b');
      expect(order.withLlm('b').llmOrderKey, 'b a');
    });

    test('every copy keeps the tail', () {
      final order = Settings.empty.withLlmOrder(['a', 'b']);
      expect(order.withReasoning(true).llmFallback, ['b']);
      expect(order.withShareTasksWithCloud(true).llmFallback, ['b']);
      expect(
        order.withProvider(ProviderConfig(id: 'c', kind: 'fake')).llmFallback,
        ['b'],
      );
      expect(order.withoutProvider('c').llmFallback, ['b']);
      expect(order.withSetupDone().llmFallback, ['b']);
      expect(
        order
            .withFinishedTaskVisibility(FinishedTaskVisibility.immediate)
            .llmFallback,
        ['b'],
      );
      expect(order.withWorkspace(const WorkspaceState(task: 'x')).llmFallback, [
        'b',
      ]);
    });

    test('withLlmOrder clears a stale problem', () {
      const broken = Settings(problem: 'was unreadable');
      expect(broken.withLlmOrder(['a']).problem, isNull);
    });

    test('unknown keys still survive a write beside the tail', () {
      final decoded = Settings.decode(
        '{"version":0,"llm":"a","llm_fallback":["b"],"future":1}',
      );
      expect(jsonDecode(decoded.encode()), {
        'version': 0,
        'llm': 'a',
        'llm_fallback': ['b'],
        'future': 1,
      });
    });
  });
}
