import 'dart:convert';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  group('ProviderConfig', () {
    test('round-trips through settings, keys sorted, absent keys omitted', () {
      final settings = Settings.empty
          .withProvider(
            ProviderConfig(
              id: 'lan',
              kind: 'openai_compatible',
              endpoint: 'https://lan.example:8443/v1',
              defaultModel: 'qwen',
              credential: 'provider:lan',
            ),
          )
          .withProvider(ProviderConfig(id: 'local', kind: 'openai_compatible'))
          .withLlm('lan');
      final text = settings.encode();
      expect(jsonDecode(text), {
        'version': 0,
        'llm': 'lan',
        'providers': [
          {
            'id': 'lan',
            'kind': 'openai_compatible',
            'endpoint': 'https://lan.example:8443/v1',
            'default_model': 'qwen',
            'credential': 'provider:lan',
          },
          {'id': 'local', 'kind': 'openai_compatible'},
        ],
      });
      final back = Settings.decode(text);
      expect(back.llm, 'lan');
      expect(back.providers.map((p) => p.id), ['lan', 'local']);
      expect(back.provider('lan')!.credential, 'provider:lan');
      expect(back.provider('local')!.endpoint, isNull);
      expect(back.provider('nope'), isNull);
    });

    test('an empty provider list is not written', () {
      expect(Settings.empty.encode(), '{"llm":null,"version":0}');
    });

    test(
      'withProvider replaces in place, withoutProvider clears a selection',
      () {
        final two = Settings.empty
            .withProvider(ProviderConfig(id: 'a', kind: 'fake'))
            .withProvider(ProviderConfig(id: 'b', kind: 'fake'))
            .withLlm('a');
        final replaced = two.withProvider(
          ProviderConfig(id: 'a', kind: 'fake', defaultModel: 'm'),
        );
        expect(replaced.providers.map((p) => p.id), ['a', 'b']);
        expect(replaced.provider('a')!.defaultModel, 'm');
        expect(replaced.llm, 'a');
        final gone = replaced.withoutProvider('a');
        expect(gone.providers.map((p) => p.id), ['b']);
        expect(gone.llm, isNull);
        expect(gone.withoutProvider('b').withoutProvider('zzz').providers, []);
      },
    );

    test('unknown keys survive inside a provider and at the top', () {
      final decoded = Settings.decode(
        '{"version":0,"llm":null,"privacy":"local",'
        '"providers":[{"id":"x","kind":"future_kind","shape":{"n":1}}]}',
      );
      expect(decoded.provider('x')!.kind, 'future_kind');
      expect(decoded.provider('x')!.extra, {
        'shape': {'n': 1},
      });
      expect(jsonDecode(decoded.withLlm('x').encode()), {
        'version': 0,
        'llm': 'x',
        'privacy': 'local',
        'providers': [
          {
            'id': 'x',
            'kind': 'future_kind',
            'shape': {'n': 1},
          },
        ],
      });
    });

    test('ids and credentials have a fixed form, endpoints are clean', () {
      ProviderConfig make({String id = 'ok', String? endpoint, String? cred}) =>
          ProviderConfig(
            id: id,
            kind: 'fake',
            endpoint: endpoint,
            credential: cred,
          );
      for (final bad in ['', 'Has-Caps', '-lead', 'sp ace', 'ü']) {
        expect(() => make(id: bad), throwsArgumentError, reason: bad);
      }
      expect(make(id: 'a-b_9').id, 'a-b_9');
      for (final bad in ['lan', 'provider:', 'provider:Lan', 'x:lan']) {
        expect(() => make(cred: bad), throwsArgumentError, reason: bad);
      }
      expect(ProviderConfig.credentialFor('lan'), 'provider:lan');
      for (final bad in [
        '',
        'lan.example',
        'ftp://lan/v1',
        'http://user:pw@lan/v1',
        'http://lan/v1?key=1',
        'http://lan/v1#frag',
        'http:///v1',
      ]) {
        expect(() => make(endpoint: bad), throwsArgumentError, reason: bad);
      }
      expect(make(endpoint: 'http://127.0.0.1:8080/v1').endpoint, isNotNull);
    });

    test('malformed providers are a format error', () {
      for (final bad in [
        '{"version":0,"providers":{}}',
        '{"version":0,"providers":[1]}',
        '{"version":0,"providers":[{"kind":"fake"}]}',
        '{"version":0,"providers":[{"id":"x"}]}',
        '{"version":0,"providers":[{"id":"x","kind":""}]}',
        '{"version":0,"providers":[{"id":"X","kind":"fake"}]}',
        '{"version":0,"providers":[{"id":"x","kind":"fake","endpoint":3}]}',
        '{"version":0,"providers":[{"id":"x","kind":"fake","endpoint":"nope"}]}',
        '{"version":0,"providers":[{"id":"x","kind":"fake","credential":"x"}]}',
        '{"version":0,"providers":[{"id":"x","kind":"fake"},{"id":"x","kind":"fake"}]}',
      ]) {
        expect(
          () => Settings.decode(bad),
          throwsA(isA<SettingsFormatException>()),
          reason: bad,
        );
      }
    });

    test('anything secret-like is refused, and the value is not echoed', () {
      const canary = 'sk-canary-9f3a1c7e2b';
      for (final bad in [
        '{"version":0,"api_key":"$canary"}',
        '{"version":0,"providers":[{"id":"x","kind":"fake","key":"$canary"}]}',
        '{"version":0,"providers":[{"id":"x","kind":"fake","Token":"$canary"}]}',
        '{"version":0,"providers":[{"id":"x","kind":"fake","note":"$canary"}]}',
        '{"version":0,"providers":[{"id":"x","kind":"fake","h":{"a":["Bearer $canary"]}}]}',
        '{"version":0,"note":"$canary"}',
      ]) {
        expect(
          () => Settings.decode(bad),
          throwsA(
            isA<SettingsFormatException>().having(
              (e) => e.toString(),
              'message',
              allOf(contains('Keychain'), isNot(contains(canary))),
            ),
          ),
          reason: bad,
        );
      }
    });

    test('toString names no credential value', () {
      expect(
        ProviderConfig(
          id: 'lan',
          kind: 'openai_compatible',
          endpoint: 'https://lan/v1',
          credential: 'provider:lan',
        ).toString(),
        'ProviderConfig(lan, openai_compatible, https://lan/v1, credential)',
      );
    });
  });
}
