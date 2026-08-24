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
    secrets = InMemorySecretStore();
    container = testContainer(
      overrides: [secretStoreProvider.overrideWithValue(secrets)],
    );
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

    expect(await run('provider add lan --kind fake --model other'), cliOk);
    expect(out.toString(), contains('updated provider lan'));
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

  test(
    'secret commands need a configured provider with a credential',
    () async {
      expect(await run('secret set nope'), cliFailed);
      expect(err.toString(), contains("no configured provider 'nope'"));
      err.clear();
      await run('provider add local --kind fake');
      expect(await run('secret set local'), cliFailed);
      expect(err.toString(), contains('takes no key'));
      expect(await run('secret status fake'), cliFailed);
      expect(secrets.accounts, isEmpty);
    },
  );

  test('removing a provider leaves its key, and says so', () async {
    await run('provider add lan --kind fake --key');
    out.clear();
    expect(await run('provider remove lan'), cliOk);
    expect(out.toString(), isNot(contains('Keychain')));
    await run('provider add lan --kind fake --key');
    await run('secret set lan');
    out.clear();
    expect(await run('provider remove lan'), cliOk);
    expect(out.toString(), contains('still in the Keychain'));
    expect(secrets.read('provider:lan'), canary);
  });
}
