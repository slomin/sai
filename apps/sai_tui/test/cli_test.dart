import 'dart:convert';
import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:sai_tui/cli.dart';
import 'package:test/test.dart';

import 'pump.dart';

void main() {
  const canary = 'sk-canary-0c9b8a7f6e5d4c3b2a1';
  late ProviderContainer container;
  late InMemorySecretStore secrets;
  late StringBuffer out;
  late StringBuffer err;
  String? secretToGive;
  final prompts = <String>[];

  setUp(() {
    container = testContainer();
    secrets = container.read(secretStoreProvider) as InMemorySecretStore;
    out = StringBuffer();
    err = StringBuffer();
    secretToGive = canary;
    prompts.clear();
  });

  Future<int> run(String line) => runCli(
    line.split(' '),
    container: container,
    out: out,
    err: err,
    readSecret: (prompt) {
      prompts.add(prompt);
      return secretToGive;
    },
  );

  File settingsFile() => container.read(settingsFileProvider);

  test('help and an unknown command', () async {
    expect(await run('help'), cliOk);
    expect(out.toString(), contains('usage: sai_tui'));
    expect(await run('frobnicate now'), cliUsageError);
    expect(err.toString(), contains('unknown command: frobnicate now'));
  });

  test('provider add, list, use, remove', () async {
    expect(await run('provider list'), cliOk);
    expect(out.toString(), contains('  fake  built-in  (fake-1)'));
    expect(out.toString(), contains('(no provider selected)'));
    out.clear();

    expect(
      await run(
        'provider add lan --kind fake --endpoint https://lan.example/v1 '
        '--model qwen --key',
      ),
      cliOk,
    );
    expect(out.toString(), contains('added provider lan'));
    expect(out.toString(), contains('sai_tui secret set lan'));
    expect(jsonDecode(settingsFile().readAsStringSync()), {
      'version': 0,
      'llm': null,
      'providers': [
        {
          'id': 'lan',
          'kind': 'fake',
          'endpoint': 'https://lan.example/v1',
          'default_model': 'qwen',
          'credential': 'provider:lan',
        },
      ],
    });
    out.clear();

    expect(await run('provider use lan'), cliOk);
    expect(out.toString().trim(), 'lan (qwen) — local · no key');
    out.clear();

    expect(await run('provider list'), cliOk);
    expect(
      out.toString(),
      contains('* lan  fake @ https://lan.example/v1  (qwen) · no key'),
    );
    out.clear();

    expect(await run('provider add lan --model other'), cliOk);
    expect(out.toString(), contains('updated provider lan'));
    final edited = container.read(settingsProvider).provider('lan')!;
    expect(edited.kind, 'fake', reason: 'unchanged options are kept');
    expect(edited.endpoint, 'https://lan.example/v1');
    expect(edited.defaultModel, 'other');
    expect(edited.credential, 'provider:lan', reason: 'the key reference too');
    expect(await run('provider add lan --no-key'), cliOk);
    expect(container.read(settingsProvider).provider('lan')?.credential, null);
    out.clear();

    expect(await run('provider use none'), cliOk);
    expect(container.read(settingsProvider).llm, isNull);
    expect(await run('provider use lan'), cliOk);
    expect(await run('provider remove lan'), cliOk);
    expect(container.read(settingsProvider).llm, isNull);
    expect(container.read(settingsProvider).providers, isEmpty);
    expect(await run('provider remove lan'), cliFailed);
    expect(err.toString(), contains("no configured provider 'lan'"));
  });

  test('an openai_compatible provider needs an endpoint and a model', () async {
    expect(await run('provider add local --kind openai_compatible'), cliOk);
    expect(
      err.toString(),
      contains(
        "provider 'local' is missing its endpoint; add it with --endpoint",
      ),
    );
    err.clear();
    expect(
      await run('provider add local --endpoint http://127.0.0.1:1234/v1'),
      cliOk,
    );
    expect(
      err.toString(),
      contains('missing its default_model; add it with --model'),
    );
    expect(await run('provider use local'), cliFailed);
    out.clear();
    expect(await run('provider list'), cliOk);
    expect(
      out.toString(),
      contains('local  openai_compatible  — missing its default_model'),
    );
    err.clear();
    out.clear();
    expect(await run('provider add local --model qwen'), cliOk);
    expect(err.toString(), isEmpty);
    expect(await run('provider use local'), cliOk);
    expect(
      out.toString(),
      contains('local @ http://127.0.0.1:1234 (qwen) — local'),
    );
    // Plaintext to another machine is refused at entry.
    expect(
      await run(
        'provider add lan --kind openai_compatible --endpoint http://lan.example/v1 --model m',
      ),
      cliUsageError,
    );
    expect(err.toString(), contains(plaintextRefused));
  });

  test(
    'moving an endpoint unbinds the key until it is entered again',
    () async {
      expect(
        await run(
          'provider add lan --kind openai_compatible --endpoint https://lan.example:8443/v1 --model qwen --key',
        ),
        cliOk,
      );
      expect(await run('secret set lan'), cliOk);
      expect(
        container.read(settingsProvider).provider('lan')!.credentialOrigin,
        'https://lan.example:8443',
      );
      out.clear();
      expect(await run('provider list'), cliOk);
      expect(out.toString(), contains('· key set'));
      out.clear();
      // Same origin, new path: still bound, no nagging.
      expect(
        await run('provider add lan --endpoint https://lan.example:8443/v2'),
        cliOk,
      );
      expect(out.toString(), isNot(contains('enter its key again')));
      expect(
        container.read(settingsProvider).provider('lan')!.keyBound,
        isTrue,
      );
      out.clear();
      // New port: unbound, said so, and the list shows it.
      expect(
        await run('provider add lan --endpoint https://lan.example:9443/v1'),
        cliOk,
      );
      expect(
        out.toString(),
        contains(
          'the endpoint moved; enter its key again: sai_tui secret set lan',
        ),
      );
      expect(
        container.read(settingsProvider).provider('lan')!.keyBound,
        isFalse,
      );
      expect(
        jsonDecode(settingsFile().readAsStringSync())['providers'][0],
        isNot(contains('credential_origin')),
      );
      out.clear();
      expect(await run('provider list'), cliOk);
      expect(out.toString(), contains('· key needs re-entry'));
      out.clear();
      expect(await run('secret set lan'), cliOk);
      expect(
        container.read(settingsProvider).provider('lan')!.credentialOrigin,
        'https://lan.example:9443',
      );
      expect(secrets.read('provider:lan'), canary);
    },
  );

  test('a malformed endpoint is a usage error, not a crash', () async {
    expect(
      await run(
        'provider add lan --kind openai_compatible --endpoint http://[::1 --model m --key',
      ),
      cliUsageError,
    );
    expect(
      err.toString(),
      contains('endpoint must be an absolute http(s) URL'),
    );
    expect(container.read(settingsProvider).provider('lan'), isNull);
  });

  test('provider add rejects what settings would reject', () async {
    expect(await run('provider add Lan --kind fake'), cliUsageError);
    expect(await run('provider add lan'), cliUsageError);
    expect(await run('provider add lan --kind'), cliUsageError);
    expect(await run('provider add lan --kind fake --bogus'), cliUsageError);
    expect(
      await run('provider add lan --kind fake --endpoint http://u:p@lan/v1'),
      cliUsageError,
    );
    expect(err.toString(), contains('userinfo'));
    expect(settingsFile().existsSync(), isFalse);
  });

  test('an unknown kind is stored with a warning and cannot be used', () async {
    expect(await run('provider add cloud --kind future'), cliOk);
    expect(err.toString(), contains("kind 'future' is not available"));
    expect(await run('provider use cloud'), cliFailed);
    out.clear();
    expect(await run('provider list'), cliOk);
    expect(out.toString(), contains('cloud  future  — kind not available'));
  });

  test('secret set, status, clear — the key is never printed', () async {
    await run('provider add lan --kind fake --key');
    out.clear();
    expect(await run('secret status lan'), cliOk);
    expect(out.toString().trim(), 'missing');
    out.clear();

    expect(await run('secret set lan'), cliOk);
    expect(prompts, ['API key for lan: ']);
    expect(secrets.read('provider:lan'), canary);
    expect(out.toString(), contains('stored in the Keychain'));
    out.clear();

    expect(await run('secret status lan'), cliOk);
    expect(out.toString().trim(), 'set');
    out.clear();

    expect(await run('provider use lan'), cliOk);
    expect(out.toString().trim(), 'lan (fake-1) — local');
    out.clear();

    expect(await run('secret clear lan'), cliOk);
    expect(out.toString(), contains('key for lan removed'));
    expect(await run('secret clear lan'), cliOk);
    expect(out.toString(), contains('no key for lan'));
    expect(secrets.accounts, isEmpty);

    final everything = '$out$err${settingsFile().readAsStringSync()}';
    expect(everything, isNot(contains(canary)));
  });

  test('secret set with nothing given changes nothing', () async {
    await run('provider add lan --kind fake --key');
    secretToGive = '';
    expect(await run('secret set lan'), cliFailed);
    expect(err.toString(), contains('no key given'));
    secretToGive = null;
    expect(await run('secret set lan'), cliFailed);
    expect(secrets.accounts, isEmpty);
  });

  test('secret set needs a configured provider with a credential', () async {
    expect(await run('secret set nope'), cliFailed);
    expect(err.toString(), contains("no configured provider 'nope'"));
    err.clear();
    await run('provider add local --kind fake');
    expect(await run('secret set local'), cliFailed);
    expect(err.toString(), contains('takes no key'));
    expect(await run('secret set Bad'), cliUsageError);
    expect(secrets.accounts, isEmpty);
  });

  test('secret status and clear work for an unconfigured id', () async {
    out.clear();
    expect(await run('secret status fake'), cliOk);
    expect(out.toString().trim(), 'missing');
    expect(await run('secret clear nope'), cliOk);
    expect(out.toString(), contains('no key for nope'));
  });

  test(
    'a key left behind by a removed provider can still be revoked',
    () async {
      await run('provider add lan --kind fake --key');
      out.clear();
      expect(await run('provider remove lan'), cliOk);
      expect(out.toString(), isNot(contains('Keychain')));
      await run('provider add lan --kind fake --key');
      await run('secret set lan');
      out.clear();
      expect(await run('provider remove lan'), cliOk);
      expect(out.toString(), contains('sai_tui secret clear lan'));
      expect(secrets.read('provider:lan'), canary);
      out.clear();
      // The advised command works, and so does asking first.
      expect(await run('secret status lan'), cliOk);
      expect(out.toString().trim(), 'set');
      expect(await run('secret clear lan'), cliOk);
      expect(out.toString(), contains('key for lan removed'));
      expect(secrets.accounts, isEmpty);
    },
  );

  test('re-keying with --no-key warns about the key left behind', () async {
    await run('provider add lan --kind fake --key');
    await run('secret set lan');
    out.clear();
    expect(await run('provider add lan --no-key'), cliOk);
    expect(out.toString(), contains('sai_tui secret clear lan'));
    expect(await run('secret clear lan'), cliOk);
    expect(secrets.accounts, isEmpty);
  });

  test(
    'none and key-looking ids are refused before anything is written',
    () async {
      expect(await run('provider add none --kind fake'), cliUsageError);
      expect(err.toString(), contains('reserved'));
      expect(await run('provider add sk-lan --kind fake'), cliUsageError);
      expect(err.toString(), contains('Keychain'));
      expect(settingsFile().existsSync(), isFalse);
    },
  );
}
