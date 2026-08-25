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

    test('privacy is local or cloud, stored and copied', () {
      final cloudy = ProviderConfig(
        id: 'cloudy',
        kind: 'fake',
        privacy: LlmPrivacy.cloud,
      );
      expect(cloudy.toJson()['privacy'], 'cloud');
      expect(ProviderConfig.fromJson(cloudy.toJson()), cloudy);
      expect(
        ProviderConfig(id: 'x', kind: 'fake').toJson(),
        isNot(contains('privacy')),
      );
      expect(cloudy.copyWith(privacy: () => null).privacy, isNull);
      expect(cloudy.copyWith(kind: 'other').privacy, LlmPrivacy.cloud);
      // A tag this sai does not know is not a reason to lose the file.
      final unknown = ProviderConfig.fromJson({
        'id': 'x',
        'kind': 'fake',
        'privacy': 'orbit',
      });
      expect(unknown.privacy, isNull);
      expect(unknown.toJson(), isNot(contains('privacy')));
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

    test('plaintext http is refused beyond this machine and the LAN', () {
      for (final ok in [
        'http://localhost:8080/v1',
        'http://127.0.0.1/v1',
        'http://127.5.5.5:1/v1',
        'http://[::1]:8080/v1',
        'http://192.168.1.20:8080/v1',
        'http://10.0.0.7/v1',
        'http://[fe80::1]:8080/v1',
        'http://sai.local:8080/v1',
        'http://box/v1',
        'https://lan.example/v1',
        'https://192.168.1.20:8443/v1',
      ]) {
        expect(() => ProviderConfig.checkEndpointForEntry(ok), returnsNormally);
      }
      for (final bad in [
        'http://lan.example/v1',
        'http://203.0.113.1/v1',
        'http://8.8.8.8:8080/v1',
        'http://0.0.0.0:8080/v1',
        'http://[2001:db8::1]:8080/v1',
      ]) {
        expect(
          () => ProviderConfig.checkEndpointForEntry(bad),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              plaintextRefused,
            ),
          ),
          reason: bad,
        );
        // Entry-time only: a stored file with such an endpoint stays
        // readable, and the transport refuses at request time.
        expect(() => ProviderConfig.checkEndpoint(bad), returnsNormally);
      }
      final stored = Settings.decode(
        '{"version":0,"llm":"lan","providers":[{"id":"lan","kind":'
        '"openai_compatible","endpoint":"http://192.168.1.5:8080/v1",'
        '"default_model":"m"},{"id":"f","kind":"fake"}]}',
      );
      expect(stored.providers.map((p) => p.id), ['lan', 'f']);
      expect(stored.llm, 'lan');
    });

    test('a malformed endpoint is an ArgumentError from every entry point', () {
      final lan = ProviderConfig(
        id: 'lan',
        kind: 'openai_compatible',
        endpoint: 'https://lan.example/v1',
        credential: 'provider:lan',
      );
      for (final bad in ['http://[::1', 'http://', '://x']) {
        expect(() => lan.copyWith(endpoint: () => bad), throwsArgumentError);
        expect(
          () => ProviderConfig.checkEndpointForEntry(bad),
          throwsArgumentError,
        );
      }
    });

    test('a key is bound to the origin it was entered for', () {
      expect(
        endpointOrigin(Uri.parse('https://lan.example:8443/v1')),
        'https://lan.example:8443',
      );
      expect(
        endpointOrigin(Uri.parse('http://[::1]:8080/v1')),
        'http://[::1]:8080',
      );
      expect(
        endpointOrigin(Uri.parse('https://lan.example/v1/')),
        'https://lan.example',
      );
      final lan = ProviderConfig(
        id: 'lan',
        kind: 'openai_compatible',
        endpoint: 'https://lan.example:8443/v1',
        credential: 'provider:lan',
      );
      expect(lan.origin, 'https://lan.example:8443');
      expect(lan.keyBound, isFalse, reason: 'no key entered yet');
      final bound = lan.copyWith(credentialOrigin: () => lan.origin);
      expect(bound.keyBound, isTrue);
      expect(bound.toJson()['credential_origin'], 'https://lan.example:8443');
      expect(
        Settings.decode(Settings.empty.withProvider(bound).encode())
            .provider('lan')!
            .keyBound,
        isTrue,
      );
      // A path change keeps the binding; a port, host or scheme change drops it.
      expect(
        bound.copyWith(endpoint: () => 'https://lan.example:8443/v2').keyBound,
        isTrue,
      );
      expect(
        bound.copyWith(endpoint: () => 'https://lan.example:9443/v1').keyBound,
        isFalse,
      );
      expect(bound.copyWith(endpoint: () => null).credentialOrigin, isNull);
      expect(bound.copyWith(credential: () => null).credentialOrigin, isNull);
      // A binding that does not fit is not a binding — never a refusal:
      // a rule tightened later must not make a stored file unreadable.
      expect(
        ProviderConfig(
          id: 'lan',
          kind: 'openai_compatible',
          endpoint: 'https://lan.example:8443/v1',
          credential: 'provider:lan',
          credentialOrigin: 'https://lan.example',
        ).credentialOrigin,
        isNull,
      );
      expect(
        ProviderConfig(
          id: 'lan',
          kind: 'fake',
          credential: 'provider:lan',
          credentialOrigin: 'https://lan.example',
        ).credentialOrigin,
        isNull,
      );
      expect(
        ProviderConfig(
          id: 'lan',
          kind: 'openai_compatible',
          endpoint: 'https://lan.example/v1',
          credentialOrigin: 'https://lan.example',
        ).credentialOrigin,
        isNull,
        reason: 'no credential to bind',
      );
      final edited = Settings.decode(
        '{"version":0,"providers":[{"id":"lan","kind":"openai_compatible",'
        '"endpoint":"https://lan.example/v1","credential":"provider:lan",'
        '"credential_origin":"https://other.example"}]}',
      ).provider('lan')!;
      expect(edited.keyBound, isFalse);
      expect(edited.toJson().containsKey('credential_origin'), isFalse);
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

    test('what the writer accepts, the reader accepts: key-looking values are refused at entry', () {
      for (final bad in [
        () => ProviderConfig(id: 'sk-lan', kind: 'fake'),
        () => ProviderConfig(id: 'lan', kind: 'fake', defaultModel: 'sk-r1'),
        () => ProviderConfig(id: 'lan', kind: 'Bearer x'),
        () => ProviderConfig(id: 'lan', kind: 'fake', extra: {'token': 'a'}),
        () => ProviderConfig(id: 'none', kind: 'fake'),
      ]) {
        expect(bad, throwsArgumentError);
      }
      expect(
        () => const Settings(extra: {'api_key': 'x'}).encode(),
        throwsArgumentError,
      );
      expect(
        () => Settings.decode(
          Settings.empty
              .withProvider(
                ProviderConfig(id: 'lan', kind: 'fake', extra: {'note': 'ok'}),
              )
              .encode(),
        ),
        returnsNormally,
      );
    });

    test('equality is over the stored form', () {
      final a = ProviderConfig(id: 'x', kind: 'fake', defaultModel: 'm');
      final b = ProviderConfig(id: 'x', kind: 'fake', defaultModel: 'm');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(a.copyWith(defaultModel: () => 'n')));
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
