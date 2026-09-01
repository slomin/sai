import 'dart:convert';
import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:sai_core/process_testing.dart';
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
    container = testContainer(finishedTasks: null);
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

  group('usage (#30)', () {
    test('a quiet day says so', () async {
      expect(await run('usage'), cliOk);
      expect(out.toString(), startsWith('no calls on '));
    });

    test('a turn shows up as a per-provider line', () async {
      await run('provider use fake');
      await container.read(tasksProvider.future);
      await container.read(chatProvider.notifier).send('hello?');
      out.clear();
      expect(await run('usage'), cliOk);
      expect(out.toString(), contains('fake · 1 call'));
      expect(out.toString(), contains('tokens'));
      // Another day holds nothing.
      out.clear();
      expect(await run('usage --day 1999-01-01'), cliOk);
      expect(out.toString(), 'no calls on 1999-01-01\n');
    });

    test('--day is strict', () async {
      expect(await run('usage --day'), cliUsageError);
      expect(err.toString(), contains('--day needs a day'));
      err.clear();
      expect(await run('usage --day yesterday'), cliUsageError);
      expect(err.toString(), contains('--day takes a day as YYYY-MM-DD'));
      err.clear();
      expect(await run('usage extra'), cliUsageError);
    });
  });

  test('the built-in endpoints are listed and selectable (#23)', () async {
    container = testContainer(builtins: builtinLlms(InMemorySecretStore()));
    expect(await run('provider list'), cliOk);
    expect(
      out.toString(),
      contains(
        '  lmstudio  built-in @ http://127.0.0.1:1234  (loaded model) · local',
      ),
    );
    expect(
      out.toString(),
      contains(
        '  lan  built-in @ http://192.168.1.5:8080  '
        '(sai-qwen38-27b-unsloth-q6k-fullctx-generic-mtp) · local',
      ),
    );
    out.clear();
    expect(await run('provider use lan'), cliOk);
    expect(
      out.toString().trim(),
      'lan @ http://192.168.1.5:8080 '
      '(sai-qwen38-27b-unsloth-q6k-fullctx-generic-mtp) — local',
    );
    expect(jsonDecode(settingsFile().readAsStringSync()), {
      'version': 0,
      'llm': 'lan',
    });
  });

  test('provider reasoning refuses an empty word as usage, not a crash; '
      'the switch says whose it is not', () async {
    expect(
      await run('provider add gpt --kind openai --model gpt-5.6-sol'),
      cliOk,
    );
    out.clear();
    final code = await run('provider reasoning gpt ');
    expect(code, isNot(cliOk));
    expect(err.toString(), isNot(contains('ArgumentError')));
    expect(
      container.read(settingsProvider).provider('gpt')!.reasoningEffort,
      isNull,
    );
    // The global switch is not an OpenAI kind's: saying so, not silence.
    expect(await run('provider use gpt'), cliOk);
    out.clear();
    expect(await run('reasoning on'), cliOk);
    expect(out.toString(), contains('provider reasoning gpt'));
  });

  test('provider add on a built-in id starts from the built-in', () async {
    container = testContainer(builtins: builtinLlms(InMemorySecretStore()));
    expect(await run('provider add lan --model other'), cliOk);
    expect(out.toString(), contains('added provider lan (over the built-in)'));
    expect(err.toString(), isEmpty);
    expect(
      jsonDecode(settingsFile().readAsStringSync()),
      containsPair('providers', [
        {
          'id': 'lan',
          'kind': 'openai_compatible',
          'endpoint': 'http://192.168.1.5:8080/v1',
          'default_model': 'other',
          'privacy': 'local',
        },
      ]),
    );
    final lan = container.read(llmRegistryProvider)['lan']!;
    expect(lan.displayName, 'lan @ http://192.168.1.5:8080');
    expect(lan.defaultModel, 'other');
    out.clear();
    // An unusable configuration hides the built-in rather than
    // routing to it.
    expect(await run('provider add lmstudio --kind future'), cliOk);
    expect(await run('provider use lmstudio'), cliFailed);
    expect(err.toString(), contains("provider 'lmstudio' is not available"));
  });

  test('OpenRouter is built in and provider add starts from its preset '
      '(#24)', () async {
    container = testContainer(builtins: builtinLlms(InMemorySecretStore()));
    expect(await run('provider list'), cliOk);
    expect(
      out.toString(),
      contains(
        '  openrouter  built-in @ https://openrouter.ai  '
        '($openRouterPresetModel) · cloud · pinned to DeepInfra fp8 · no key',
      ),
    );
    expect(settingsFile().existsSync(), isFalse);
    out.clear();
    expect(await run('provider add openrouter'), cliOk);
    expect(
      out.toString(),
      contains('added provider openrouter (over the built-in)'),
    );
    expect(out.toString(), contains('routing: pinned to DeepInfra fp8'));
    expect(
      out.toString(),
      contains('set its key with: sai_tui secret set openrouter'),
    );
    expect(err.toString(), isEmpty);
    Map<String, Object?> entry() =>
        (jsonDecode(settingsFile().readAsStringSync())['providers'] as List)
                .single
            as Map<String, Object?>;
    expect(entry(), {
      'id': 'openrouter',
      'kind': 'openrouter',
      'default_model': openRouterPresetModel,
      'credential': 'provider:openrouter',
      'privacy': 'cloud',
      'routing': 'deepinfra_fp8',
    });
    // A model of one's own is exact routing, said so.
    out.clear();
    expect(await run('provider add openrouter --model qwen/qwen3-8b'), cliOk);
    expect(out.toString(), contains('routing: exact model'));
    expect(entry()['default_model'], 'qwen/qwen3-8b');
    expect(entry()['routing'], 'exact');
    final built = container.read(llmRegistryProvider)['openrouter']!;
    expect(built.defaultModel, 'qwen/qwen3-8b');
    expect(built.privacy, LlmPrivacy.cloud);
    // The preset model by hand stays exact; --routing recommended pins.
    out.clear();
    expect(
      await run('provider add openrouter --model $openRouterPresetModel'),
      cliOk,
    );
    expect(entry()['routing'], 'exact');
    expect(await run('provider add openrouter --routing recommended'), cliOk);
    expect(entry()['default_model'], openRouterPresetModel);
    expect(entry()['routing'], 'deepinfra_fp8');
    expect(out.toString(), contains('routing: pinned to DeepInfra fp8'));
    // What is refused, with the entry untouched.
    final before = entry();
    for (final (line, why) in [
      (
        'provider add openrouter --routing recommended --model qwen/qwen3-8b',
        'pins',
      ),
      ('provider add openrouter --model openrouter/auto', 'routers that pick'),
      ('provider add openrouter --model ~deepseek/latest', 'owner/name'),
      ('provider add openrouter --model qwen/qwen3-8b:nitro', 'shortcut'),
      (
        'provider add openrouter --endpoint https://x.example/v1',
        'fixed endpoint',
      ),
      ('provider add openrouter --privacy local', 'cloud provider'),
      ('provider add openrouter --no-key', 'needs a key'),
      ('provider add openrouter --routing cheapest', 'recommended or exact'),
      ('provider add lan --routing exact', 'openrouter only'),
    ]) {
      err.clear();
      expect(await run(line), cliUsageError, reason: line);
      expect(err.toString(), contains(why), reason: line);
    }
    expect(entry(), before);
    expect(container.read(settingsProvider).provider('lan'), isNull);
  });

  test(
    'changing an entry to openrouter drops what the kind refuses (#24)',
    () async {
      container = testContainer(builtins: builtinLlms(InMemorySecretStore()));
      expect(
        await run(
          'provider add local --kind openai_compatible '
          '--endpoint http://127.0.0.1:8080/v1 --model qwen --privacy local',
        ),
        cliOk,
      );
      out.clear();
      err.clear();
      expect(
        await run('provider add local --kind openrouter --model qwen/qwen3-8b'),
        cliOk,
      );
      expect(err.toString(), isEmpty, reason: 'nothing inherited is refused');
      expect(out.toString(), contains('routing: exact model'));
      Map<String, Object?> entry() =>
          (jsonDecode(settingsFile().readAsStringSync())['providers'] as List)
                  .single
              as Map<String, Object?>;
      expect(entry(), {
        'id': 'local',
        'kind': 'openrouter',
        'default_model': 'qwen/qwen3-8b',
        'credential': 'provider:local',
        'privacy': 'cloud',
        'routing': 'exact',
      });
      final built = container.read(llmRegistryProvider)['local']!;
      expect(built.privacy, LlmPrivacy.cloud);
      expect(built.displayName, 'local @ http://127.0.0.1:1');
      // And back: the routing word is OpenRouter's, it does not travel.
      out.clear();
      expect(
        await run(
          'provider add local --kind openai_compatible '
          '--endpoint http://127.0.0.1:8080/v1 --model qwen',
        ),
        cliOk,
      );
      expect(entry(), isNot(contains('routing')));
      expect(entry()['credential'], 'provider:local', reason: 'the key stays');
    },
  );

  test(
    "a built-in's key account is not carried into another kind (#24)",
    () async {
      container = testContainer(builtins: builtinLlms(InMemorySecretStore()));
      expect(
        await run(
          'provider add openrouter --kind openai_compatible '
          '--endpoint http://192.168.1.5:8080/v1 --model qwen',
        ),
        cliOk,
      );
      Map<String, Object?> entry() =>
          (jsonDecode(settingsFile().readAsStringSync())['providers'] as List)
                  .single
              as Map<String, Object?>;
      expect(entry(), isNot(contains('credential')));
      expect(entry(), isNot(contains('routing')));
      expect(out.toString(), isNot(contains('secret set')));
      expect(
        await run(
          'provider add openrouter --kind openai_compatible '
          '--endpoint http://192.168.1.5:8080/v1 --model qwen --key',
        ),
        cliOk,
      );
      expect(entry()['credential'], 'provider:openrouter');
    },
  );

  test('a wrong OpenRouter value is said as such and repaired by adding '
      'again (#24)', () async {
    container = testContainer(builtins: builtinLlms(InMemorySecretStore()));
    // As a hand-edited file would have it: an endpoint on the kind.
    container
        .read(settingsProvider.notifier)
        .upsertProvider(
          ProviderConfig(
            id: 'openrouter',
            kind: 'openrouter',
            endpoint: 'https://other.example/v1',
            defaultModel: openRouterPresetModel,
            credential: 'provider:openrouter',
            routing: 'deepinfra_fp8',
          ),
        );
    expect(await run('provider list'), cliOk);
    expect(
      out.toString(),
      contains(
        '  openrouter  openrouter  — carrying an endpoint, but openrouter '
        'has a fixed one',
      ),
    );
    expect(out.toString(), isNot(contains('missing its')));
    out.clear();
    err.clear();
    expect(await run('provider add openrouter --routing recommended'), cliOk);
    expect(err.toString(), isEmpty);
    final entry =
        (jsonDecode(settingsFile().readAsStringSync())['providers'] as List)
                .single
            as Map<String, Object?>;
    expect(entry, isNot(contains('endpoint')));
    expect(container.read(llmRegistryProvider), contains('openrouter'));
  });

  test(
    'secret set configures the OpenRouter built-in as shipped (#24)',
    () async {
      final store = InMemorySecretStore();
      container = testContainer(builtins: builtinLlms(store), secrets: store);
      expect(await run('secret status openrouter'), cliOk);
      expect(out.toString().trim(), 'missing');
      out.clear();
      expect(await run('secret set openrouter'), cliOk);
      expect(prompts, ['API key for openrouter: ']);
      expect(
        out.toString().trim(),
        'key for openrouter stored in the Keychain (openrouter configured as '
        'shipped)',
      );
      expect(store.accounts, ['provider:openrouter']);
      expect(store.read('provider:openrouter'), canary);
      final saved = jsonDecode(settingsFile().readAsStringSync());
      expect(saved['providers'], [
        {
          'id': 'openrouter',
          'kind': 'openrouter',
          'default_model': openRouterPresetModel,
          'credential': 'provider:openrouter',
          'privacy': 'cloud',
          'routing': 'deepinfra_fp8',
        },
      ]);
      out.clear();
      expect(await run('provider list'), cliOk);
      expect(
        out.toString(),
        contains(
          '  openrouter  openrouter  ($openRouterPresetModel) · cloud · '
          'pinned to DeepInfra fp8 · key set',
        ),
      );
      // A second key replaces, the entry stays; clear removes the item.
      out.clear();
      expect(await run('secret set openrouter'), cliOk);
      expect(
        out.toString().trim(),
        'key for openrouter stored in the Keychain',
      );
      // Re-adding over a stored key does not ask for the key again.
      out.clear();
      expect(await run('provider remove openrouter'), cliOk);
      out.clear();
      expect(await run('provider add openrouter'), cliOk);
      expect(out.toString(), isNot(contains('set its key')));
      expect(await run('secret clear openrouter'), cliOk);
      expect(store.accounts, isEmpty);
      expect(
        container.read(settingsProvider).provider('openrouter'),
        isNotNull,
      );
      // The keyless built-ins are still refused.
      err.clear();
      expect(await run('secret set lan'), cliFailed);
      expect(err.toString(), contains("no configured provider 'lan'"));
      final everything = '$out$err${settingsFile().readAsStringSync()}';
      expect(everything, isNot(contains(canary)));
    },
  );

  test('version prints the workspace version', () async {
    expect(await run('version'), cliOk);
    expect(out.toString().trim(), 'sai_tui $saiVersion');
    out.clear();
    expect(await run('--version'), cliOk);
    expect(out.toString().trim(), 'sai_tui $saiVersion');
  });

  test('the dev client names itself sai_tui-dev everywhere (#90)', () async {
    container = testContainer(
      overrides: [identityProvider.overrideWithValue(SaiIdentity.dev)],
    );
    expect(await run('version'), cliOk);
    expect(out.toString().trim(), 'sai_tui-dev $saiVersion');
    out.clear();
    expect(await run('help'), cliOk);
    expect(out.toString(), contains('usage: sai_tui-dev '));
    expect(out.toString(), isNot(contains('sai_tui ')));
    // Every column of the table moves by exactly the name's extra width,
    // so what lined up for sai_tui still lines up; the prose is untouched.
    final dev = usageFor('sai_tui-dev').split('\n');
    final stable = cliUsage.split('\n');
    expect(dev.length, stable.length);
    const extra = 'sai_tui-dev'.length - 'sai_tui'.length;
    for (final text in [
      'open the terminal client',
      'show the cloud-sharing switch',
      'print the version',
      '[--model <name>]',
      '(or from stdin when piped)',
      '[--open-only]',
      'bring the Things 3 database over',
    ]) {
      final was = stable.firstWhere((l) => l.contains(text));
      final now = dev.firstWhere((l) => l.contains(text));
      expect(now.indexOf(text), was.indexOf(text) + extra, reason: now);
    }
    final prose = stable.indexOf('');
    expect(dev.sublist(prose), stable.sublist(prose));
    expect(usageFor('sai_tui'), cliUsage);
    expect(out.toString(), contains('Provider settings go to settings.json'));
    expect(await run('frobnicate now'), cliUsageError);
    expect(err.toString(), startsWith('sai_tui-dev: '));
    expect(await run('provider add lan --kind fake --key'), cliOk);
    // The key lives in the stable copy (#95): the hint says which one.
    expect(out.toString(), contains('sai_tui secret set lan'));
  });

  test('help and an unknown command', () async {
    expect(await run('help'), cliOk);
    expect(out.toString(), contains('usage: sai_tui'));
    expect(await run('frobnicate now'), cliUsageError);
    expect(err.toString(), contains('unknown command: frobnicate now'));
  });

  test('provider add, list, use, remove', () async {
    expect(await run('provider list'), cliOk);
    expect(out.toString(), contains('  fake  built-in  (fake-1) · local'));
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
      contains('* lan  fake @ https://lan.example/v1  (qwen) · local · no key'),
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

  test('the two OpenAI kinds are added apart, each with its own billing '
      '(#26)', () async {
    Map<String, Object?> entry(String id) =>
        (jsonDecode(settingsFile().readAsStringSync())['providers'] as List)
            .cast<Map<String, Object?>>()
            .singleWhere((p) => p['id'] == id);
    // The API key kind: cloud, keyed, one exact model, effort by default.
    expect(
      await run('provider add openai --kind openai --model gpt-5.6-sol'),
      cliOk,
    );
    expect(out.toString(), contains('added provider openai'));
    expect(out.toString(), contains('reasoning effort: Model default'));
    expect(
      out.toString(),
      contains('set its key with: sai_tui secret set openai'),
    );
    expect(entry('openai'), {
      'id': 'openai',
      'kind': 'openai',
      'default_model': 'gpt-5.6-sol',
      'credential': 'provider:openai',
      'privacy': 'cloud',
    });
    // The effort is its own choice: set, changed, returned to the default,
    // never touching the model.
    out.clear();
    expect(await run('provider add openai --effort xhigh'), cliOk);
    expect(out.toString(), contains('reasoning effort: xhigh'));
    expect(entry('openai')['reasoning_effort'], 'xhigh');
    expect(entry('openai')['default_model'], 'gpt-5.6-sol');
    expect(await run('provider add openai --model gpt-5.6-luna'), cliOk);
    expect(entry('openai')['reasoning_effort'], 'xhigh');
    expect(entry('openai')['default_model'], 'gpt-5.6-luna');
    expect(await run('provider add openai --effort default'), cliOk);
    expect(entry('openai'), isNot(contains('reasoning_effort')));
    // The subscription kind: cloud, no key, the model may come later.
    out.clear();
    expect(
      await run('provider add chatgpt --kind chatgpt_subscription'),
      cliOk,
    );
    expect(out.toString(), contains('added provider chatgpt'));
    expect(out.toString(), contains('reasoning effort: Model default'));
    expect(
      out.toString(),
      contains('sign in with: sai_tui provider login chatgpt'),
    );
    expect(out.toString(), isNot(contains('secret set')));
    expect(entry('chatgpt'), {
      'id': 'chatgpt',
      'kind': 'chatgpt_subscription',
      'privacy': 'cloud',
    });
    expect(
      await run('provider add chatgpt --model gpt-5.6-sol --effort high'),
      cliOk,
    );
    expect(entry('chatgpt')['default_model'], 'gpt-5.6-sol');
    expect(entry('chatgpt')['reasoning_effort'], 'high');
    // What is refused, with both entries untouched.
    final before = (entry('openai'), entry('chatgpt'));
    for (final (line, why) in [
      ('provider add openai --endpoint https://x.example/v1', 'fixed endpoint'),
      ('provider add openai --privacy local', 'cloud provider'),
      ('provider add openai --no-key', 'needs a key'),
      ('provider add openai --routing exact', 'openrouter only'),
      ('provider add key --kind openai', 'needs --model'),
      (
        'provider add chatgpt --endpoint https://x.example/v1',
        'fixed endpoint',
      ),
      ('provider add chatgpt --privacy local', 'cloud provider'),
      ('provider add chatgpt --key', 'takes no key'),
      ('provider add chatgpt --routing exact', 'openrouter only'),
      (
        'provider add plain --kind fake --effort high',
        'openai and chatgpt_subscription only',
      ),
      ('provider add openai --effort', '--effort needs a value'),
    ]) {
      err.clear();
      expect(await run(line), cliUsageError, reason: line);
      expect(err.toString(), contains(why), reason: line);
    }
    expect(entry('openai'), before.$1);
    expect(entry('chatgpt'), before.$2);
    expect(container.read(settingsProvider).provider('key'), isNull);
    expect(container.read(settingsProvider).provider('plain'), isNull);
    // An entry changed to an OpenAI kind drops what the kind refuses.
    expect(
      await run(
        'provider add box --kind openai_compatible '
        '--endpoint http://127.0.0.1:8080/v1 --model m --key',
      ),
      cliOk,
    );
    expect(await run('provider add box --kind openai'), cliOk);
    expect(entry('box'), {
      'id': 'box',
      'kind': 'openai',
      'default_model': 'm',
      'credential': 'provider:box',
      'privacy': 'cloud',
    });
    expect(await run('provider add box --kind chatgpt_subscription'), cliOk);
    expect(entry('box'), {
      'id': 'box',
      'kind': 'chatgpt_subscription',
      'default_model': 'm',
      'privacy': 'cloud',
    });
  });

  group('the ChatGPT commands (#26)', () {
    late FakeAppServer server;
    late Directory sidecarDir;

    setUp(() {
      server = FakeAppServer();
      sidecarDir = Directory.systemTemp.createTempSync('sai_cli_sidecar');
      File('${sidecarDir.path}/codex-app-server').writeAsStringSync('stub');
      container = testContainer(
        overrides: [
          processRunnerProvider.overrideWithValue(server.runner),
          sidecarLocatorProvider.overrideWithValue(
            SidecarLocator('${sidecarDir.path}/codex-app-server'),
          ),
          codexHomeProvider.overrideWithValue(
            Directory('${sidecarDir.path}/home/codex'),
          ),
        ],
      );
    });

    tearDown(() {
      container.dispose();
      sidecarDir.deleteSync(recursive: true);
    });

    test('account, models, reasoning and logout, in the fixed words', () async {
      expect(
        await run('provider add chatgpt --kind chatgpt_subscription'),
        cliOk,
      );
      out.clear();
      expect(await run('provider account chatgpt'), cliOk);
      expect(
        out.toString(),
        contains('signed in to ChatGPT as person@example.com · pro plan'),
      );
      expect(out.toString(), contains('plan usage: 25% used'));
      expect(out.toString(), isNot(contains('\$')), reason: 'never money');
      out.clear();
      expect(await run('provider models chatgpt'), cliOk);
      expect(
        out.toString(),
        contains(
          'gpt-5.6-sol  GPT-5.6 Sol (default) · default effort medium · efforts: low, medium, high, xhigh',
        ),
      );
      expect(
        out.toString(),
        contains(
          'gpt-5.6-luna  GPT-5.6 Luna · default effort medium · efforts: low, high',
        ),
      );
      expect(out.toString(), isNot(contains('hidden')));
      out.clear();
      expect(await run('provider add chatgpt --model gpt-5.6-luna'), cliOk);
      expect(await run('provider reasoning chatgpt'), cliOk);
      expect(
        out.toString(),
        contains('chatgpt: reasoning effort Model default'),
      );
      out.clear();
      expect(await run('provider reasoning chatgpt high'), cliOk);
      expect(out.toString(), contains('chatgpt: reasoning effort high'));
      final entry =
          (jsonDecode(settingsFile().readAsStringSync())['providers'] as List)
              .cast<Map<String, Object?>>()
              .single;
      expect(entry['reasoning_effort'], 'high');
      expect(entry['default_model'], 'gpt-5.6-luna');
      out.clear();
      expect(await run('provider reasoning chatgpt default'), cliOk);
      expect(out.toString(), contains('Model default'));
      expect(await run('provider reasoning chatgpt a b'), cliUsageError);
      out.clear();
      expect(await run('provider list'), cliOk);
      expect(
        out.toString(),
        contains(
          'chatgpt  chatgpt_subscription  (gpt-5.6-luna) · cloud · ChatGPT subscription · effort default',
        ),
      );
      out.clear();
      expect(await run('provider logout chatgpt'), cliOk);
      expect(
        out.toString(),
        contains('signed out of ChatGPT; not signed in to ChatGPT'),
      );
      expect(server.logouts, 1);
      err.clear();
      expect(await run('provider models chatgpt'), cliFailed);
      expect(err.toString(), contains(CodexText.signedOut));
      // The runtime saw sai's environment alone.
      for (final spawn in server.runner.spawns) {
        expect(spawn.environment.keys, isNot(contains('OPENAI_API_KEY')));
        expect(spawn.executable, '/usr/bin/sandbox-exec');
      }
      // Nothing of the account on disk.
      expect(
        settingsFile().readAsStringSync(),
        isNot(contains('person@example.com')),
      );
    });

    test(
      'login prints the URL or the code — never a token — and waits',
      () async {
        expect(
          await run('provider add chatgpt --kind chatgpt_subscription'),
          cliOk,
        );
        server.account = null;
        out.clear();
        // Device code: the completion arrives while the command waits.
        final pending = run('provider login chatgpt --device-code');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          out.toString(),
          contains(
            'open https://auth.openai.com/codex/device and enter the code ABCD-1234',
          ),
        );
        expect(out.toString(), contains('waiting for the sign-in'));
        server.account = {
          'type': 'chatgpt',
          'email': 'p@example.com',
          'planType': 'plus',
        };
        server.runner.processes.single.notify('account/login/completed', {
          'loginId': 'login-1',
          'success': true,
        });
        expect(await pending, cliOk);
        expect(
          out.toString(),
          contains('signed in to ChatGPT as p@example.com · plus plan'),
        );
        expect(out.toString(), isNot(contains('token')));
        // Browser: the URL only.
        out.clear();
        server.account = null;
        final browser = run('provider login chatgpt');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          out.toString(),
          contains('open this URL in your browser to sign in:'),
        );
        expect(
          out.toString(),
          contains('https://auth.openai.com/oauth/authorize?state=login-2'),
        );
        server.runner.processes.single.notify('account/login/completed', {
          'loginId': 'login-2',
          'success': false,
          'error': 'expired',
        });
        expect(await browser, cliFailed);
        expect(err.toString(), contains(CodexText.loginFailed));
        expect(await run('provider login chatgpt --browser'), cliUsageError);
      },
    );

    test('the wrong kind, a missing entry, and the openai list', () async {
      err.clear();
      expect(await run('provider account nothing'), cliFailed);
      expect(err.toString(), contains('no provider nothing is configured'));
      expect(await run('provider add lan2 --kind fake'), cliOk);
      err.clear();
      expect(await run('provider login lan2'), cliFailed);
      expect(
        err.toString(),
        contains("provider 'lan2' is fake, not chatgpt_subscription"),
      );
      err.clear();
      expect(await run('provider reasoning lan2 high'), cliFailed);
      expect(err.toString(), contains('keeps the reasoning on|off switch'));
      expect(
        server.runner.spawns,
        isEmpty,
        reason: 'nothing spawned for the wrong kind',
      );
    });
  });

  test('the dev client runs no ChatGPT runtime (#26, #95)', () async {
    container = testContainer(
      overrides: [identityProvider.overrideWithValue(SaiIdentity.dev)],
    );
    expect(
      await run('provider add chatgpt --kind chatgpt_subscription'),
      cliOk,
    );
    for (final line in [
      'provider login chatgpt',
      'provider account chatgpt',
      'provider models chatgpt',
      'provider logout chatgpt',
    ]) {
      err.clear();
      expect(await run(line), cliFailed, reason: line);
      expect(err.toString(), contains(CodexText.devRefused), reason: line);
      expect(err.toString(), contains('sai_tui'), reason: line);
    }
    // The effort is a setting; the dev copy may set it.
    expect(await run('provider reasoning chatgpt high'), cliOk);
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

  test('the dev client holds no credentials (#95)', () async {
    container = testContainer(
      overrides: [identityProvider.overrideWithValue(SaiIdentity.dev)],
    );
    expect(await run('provider add lan --kind fake --key'), cliOk);
    expect(out.toString(), contains('sai_tui secret set lan'));
    expect(out.toString(), isNot(contains('sai_tui-dev secret set')));
    out.clear();
    expect(await run('provider list'), cliOk);
    expect(out.toString(), contains('· no credentials in dev'));
    out.clear();
    for (final verb in ['set', 'status', 'clear']) {
      err.clear();
      expect(await run('secret $verb lan'), cliFailed);
      expect(
        err.toString().trim(),
        'sai_tui-dev holds no credentials (ADR 0019); use sai_tui',
      );
    }
    expect(prompts, isEmpty);
    expect(out.toString(), isEmpty);
    // Keyless providers are untouched.
    expect(await run('provider use fake'), cliOk);
    expect(out.toString().trim(), 'fake (fake-1) — local');
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

  test('the privacy switch: off by default, shown, flipped, warned', () async {
    expect(await run('privacy'), cliOk);
    expect(
      out.toString().trim(),
      'cloud sharing: off — cloud providers do not see your tasks',
    );
    out.clear();

    expect(await run('provider add cloudy --kind fake --privacy cloud'), cliOk);
    expect(
      jsonDecode(settingsFile().readAsStringSync()),
      containsPair('providers', [
        {'id': 'cloudy', 'kind': 'fake', 'privacy': 'cloud'},
      ]),
    );
    expect(await run('provider list'), cliOk);
    expect(out.toString(), contains('  cloudy  fake  (fake-1) · cloud'));
    out.clear();

    expect(await run('provider use cloudy'), cliOk);
    expect(out.toString().split('\n').where((l) => l.isNotEmpty), [
      'cloudy (fake-1) — cloud · tasks withheld',
      "cloud provider 'cloudy' will not see your tasks until sharing is on: "
          'sai_tui privacy share-tasks on',
    ]);
    out.clear();

    expect(await run('privacy share-tasks on'), cliOk);
    expect(
      out.toString().trim(),
      'cloud sharing: on — cloud providers see your tasks',
    );
    expect(container.read(settingsProvider).shareTasksWithCloud, isTrue);
    expect(container.read(llmStatusProvider), 'cloudy (fake-1) — cloud');
    out.clear();
    expect(await run('provider use cloudy'), cliOk);
    expect(out.toString().trim(), 'cloudy (fake-1) — cloud');
    out.clear();

    expect(await run('privacy share-tasks off'), cliOk);
    expect(out.toString().split('\n').where((l) => l.isNotEmpty), [
      'cloud sharing: off — cloud providers do not see your tasks',
      "cloud provider 'cloudy' will not see your tasks until sharing is on",
    ]);
    expect(container.read(settingsProvider).shareTasksWithCloud, isFalse);
    out.clear();

    expect(await run('privacy share-tasks sideways'), cliUsageError);
    expect(err.toString(), contains('share-tasks takes on or off'));
    err.clear();
    expect(await run('provider add cloudy --privacy lan'), cliUsageError);
    expect(err.toString(), contains('--privacy takes local or cloud'));
    err.clear();
    // Any kind takes the tag; a public host is cloud unless told otherwise.
    expect(
      await run(
        'provider add hosted --kind openai_compatible '
        '--endpoint https://api.example.com/v1 --model m',
      ),
      cliOk,
    );
    expect(await run('provider list'), cliOk);
    expect(
      out.toString(),
      contains(
        'hosted  openai_compatible @ https://api.example.com/v1  (m) · cloud',
      ),
    );
    out.clear();
    expect(await run('provider add hosted --privacy local'), cliOk);
    expect(await run('provider list'), cliOk);
    expect(out.toString(), contains('(m) · local'));
    out.clear();
    // Changing the kind of a tagged provider keeps the tag.
    expect(
      await run(
        'provider add cloudy --kind openai_compatible '
        '--endpoint http://127.0.0.1:1 --model m',
      ),
      cliOk,
    );
    expect(
      container.read(settingsProvider).provider('cloudy')!.privacy,
      LlmPrivacy.cloud,
    );
    expect(await run('provider add cloudy --kind fake'), cliOk);
    // An edit that names no --privacy keeps the tag.
    err.clear();
    expect(await run('provider add cloudy --model m2'), cliOk);
    expect(
      container.read(settingsProvider).provider('cloudy')!.privacy,
      LlmPrivacy.cloud,
    );
  });

  test('reasoning shows, sets and refuses', () async {
    expect(await run('reasoning'), cliOk);
    expect(out.toString().trim(), reasoningLine(false));
    out.clear();
    expect(await run('reasoning on'), cliOk);
    expect(out.toString().trim(), reasoningLine(true));
    expect(container.read(settingsProvider).reasoningOn, isTrue);
    expect(
      jsonDecode(settingsFile().readAsStringSync()),
      containsPair('reasoning', true),
    );
    out.clear();
    expect(await run('reasoning off'), cliOk);
    expect(container.read(settingsProvider).reasoningOn, isFalse);
    expect(await run('reasoning maybe'), cliUsageError);
    expect(err.toString(), contains('reasoning takes on or off'));
  });

  test('finished-tasks shows, sets and refuses (#97)', () async {
    expect(await run('finished-tasks'), cliOk);
    expect(
      out.toString().trim(),
      finishedTasksLine(FinishedTaskVisibility.endOfDay),
    );
    out.clear();
    expect(await run('finished-tasks immediate'), cliOk);
    expect(
      out.toString().trim(),
      finishedTasksLine(FinishedTaskVisibility.immediate),
    );
    expect(
      container.read(settingsProvider).finishedTaskVisibility,
      FinishedTaskVisibility.immediate,
    );
    expect(
      jsonDecode(settingsFile().readAsStringSync()),
      containsPair('finished_task_visibility', 'immediate'),
    );
    out.clear();
    expect(await run('finished-tasks end-of-day'), cliOk);
    expect(
      container.read(settingsProvider).finishedTaskVisibility,
      FinishedTaskVisibility.endOfDay,
    );
    expect(
      jsonDecode(settingsFile().readAsStringSync()),
      isNot(contains('finished_task_visibility')),
    );
    expect(await run('finished-tasks never'), cliUsageError);
    expect(
      err.toString(),
      contains('finished-tasks takes end-of-day or immediate'),
    );
  });
}
