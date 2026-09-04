import 'dart:async';
import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';

/// What `sai_tui <command>` prints for `help` and for a usage error.
const cliUsage = '''
usage: sai_tui                       open the terminal client
       sai_tui provider list
       sai_tui provider add <id> --kind <kind> [--endpoint <url>]
                                    [--model <name>] [--key | --no-key]
                                    [--privacy local|cloud]
                                    [--routing recommended|exact]
                                    [--effort default|<word>]
       sai_tui provider remove <id>
       sai_tui provider use <id|none>
                                    put a provider first in the order
       sai_tui provider order [<id> ...]
                                    show or set the fallback order
       sai_tui provider login <id> [--device-code]
                                    sign in to ChatGPT (chatgpt_subscription)
       sai_tui provider account <id> who is signed in, and the plan's usage
       sai_tui provider models <id>  the models a ChatGPT plan or a key offers
       sai_tui provider reasoning <id> [default|<word>]
                                    the effort an OpenAI kind asks for
       sai_tui provider logout <id>  sign out of ChatGPT
       sai_tui privacy               show the cloud-sharing switch
       sai_tui privacy share-tasks on|off
       sai_tui reasoning [on|off]    let the model think before answering
       sai_tui finished-tasks [end-of-day|immediate]
                                    when a finished task leaves its list
       sai_tui usage [--day YYYY-MM-DD]
                                    what the models did that day
       sai_tui secret set <id>       read the key from a hidden prompt
                                    (or from stdin when piped)
       sai_tui secret clear <id>
       sai_tui secret status <id>
       sai_tui things import [--dry-run] [--db <main.sqlite>]
                            [--open-only] [--skip-repeat-history]
                            [--logbook-since YYYY-MM-DD]
                                    bring the Things 3 database over
       sai_tui version               print the version
       sai_tui help

Provider settings go to settings.json; keys go to the Keychain and are
never written to a file or printed. --key files the key under
provider:<id>; adding an existing id changes only the options given
(docs/settings/settings-v0.md). A key is bound to the endpoint it was
entered for: after --endpoint moves a provider to another host, port or
scheme, enter its key again. secret clear and status also work for a
provider that is no longer configured. A cloud provider sees your tasks
only while share-tasks is on (off by default). --privacy says where a
provider's inference happens; without it the fake is local and an
openai_compatible endpoint is local on this machine or the LAN and cloud
on any other host. finished-tasks end-of-day (the default) keeps a task
completed or cancelled today greyed in its lists until midnight;
immediate drops it into the Logbook at once.

openrouter is built in: cloud, keyed, fixed to https://openrouter.ai,
on its recommended preset (DeepSeek V4 Flash 0731 pinned to DeepInfra
fp8, no fallback). provider add openrouter --model <owner/name> picks
one exact model instead (routing exact) — it needs an endpoint that
meets sai's privacy filters, zero retention above all (openrouter.ai
lists them), or every call is refused; --routing recommended returns
to the preset. It takes no --endpoint and no --privacy local (an entry
changed to this kind drops the endpoint it had and turns cloud), and
openrouter/* routers, ~latest aliases and :nitro/:floor/:online
shortcuts are refused. secret set openrouter configures it as shipped
and files the key. Removing the key here removes the Keychain item
only: revoke the key at openrouter.ai as well.

OpenAI is two kinds, never one (#26): --kind openai is the Responses
API on an API key, billed to your OpenAI project, fixed to
https://api.openai.com, needing --model <exact id> and a key (secret
set <id>); --kind chatgpt_subscription is your ChatGPT plan through
OpenAI's Codex App Server, which sai runs as a child — no key, no
endpoint, signed in with provider login <id>. Both are cloud; neither
takes --endpoint, --privacy local or --routing, and a failure on one is
never retried on the other. --effort chooses how hard the model thinks
for these two kinds alone: default leaves it to the model, any other
word goes to the backend exactly as typed (openai: none, minimal, low,
medium, high, xhigh, max — which of them a model takes is the model's
business; chatgpt_subscription: what provider models <id> lists for the
chosen model). Other kinds keep the reasoning on|off switch.

things import reads a private copy of the Things 3 database (the one
under ~/Library/Group Containers, or --db / SAI_THINGS_DB) and writes
what is new or changed into the archive as system events; run it again
and only the differences land. --dry-run prints what a run would do and
writes nothing. Things itself is never written to. For a switch rather
than a mirror, leave history behind: --open-only imports no finished
task, --skip-repeat-history drops the completion history of repeating
tasks (their open next instances still come), --logbook-since keeps
only tasks finished on or after that day; each reports what it left.''';

/// [cliUsage] for the command a flavor is installed as (`sai_tui` for
/// stable, `sai_tui-dev` for dev, ADR 0019). The text is written once for
/// `sai_tui`; in the table only the command word is renamed — what
/// follows it on the line moves with it, and a continuation line (no
/// command word) is indented by the same amount — so the columns stay
/// aligned, and the prose below the table is never touched.
String usageFor(String program) {
  const width = 'sai_tui'.length;
  final shift = ' ' * (program.length - width);
  final command = RegExp(r'^(usage: |       )sai_tui(.*)$');
  final lines = cliUsage.split('\n');
  final end = lines.indexOf('');
  return [
    for (final (i, line) in lines.indexed)
      if (i >= end)
        line
      else if (command.firstMatch(line) case final m?)
        '${m[1]}$program${m[2]}'
      else
        '$shift$line',
  ].join('\n');
}

/// What `usage` prints per provider: the shared words after the name.
String usageLine(DailyUsage row) => '${row.provider} · ${usageWords(row)}';

/// What `privacy` prints for each position of the switch.
String privacyLine(PrivacyPolicy policy) => policy.shareTasksWithCloud
    ? 'cloud sharing: on — cloud providers see your tasks'
    : 'cloud sharing: off — cloud providers do not see your tasks';

/// What `reasoning` prints for each position of the switch.
String reasoningLine(bool on) => on
    ? 'reasoning: on — the model thinks before it answers, and shows it'
    : 'reasoning: off — the model answers directly';

/// What `finished-tasks` prints for each policy.
String finishedTasksLine(FinishedTaskVisibility visibility) =>
    switch (visibility) {
      FinishedTaskVisibility.endOfDay =>
        'finished tasks: end-of-day — stay greyed in their lists until '
            'midnight',
      FinishedTaskVisibility.immediate =>
        'finished tasks: immediate — leave for the Logbook at once',
    };

/// Exit codes, as a shell expects them.
const cliOk = 0;
const cliFailed = 1;
const cliUsageError = 2;

/// Runs one non-interactive command against [container] and returns the
/// exit code. Output goes to [out] and [err], never a secret; the secret
/// for `secret set` comes from [readSecret], which the binary wires to a
/// hidden prompt and tests to a fixed string.
Future<int> runCli(
  List<String> args, {
  required ProviderContainer container,
  required StringSink out,
  required StringSink err,
  required FutureOr<String?> Function(String prompt) readSecret,
}) async {
  final program = container.read(identityProvider).tuiCommand;
  if (args.isEmpty || args.first == 'help' || args.first == '--help') {
    out.writeln(usageFor(program));
    return cliOk;
  }
  if (args.first == 'version' || args.first == '--version') {
    out.writeln('$program $saiVersion');
    return cliOk;
  }
  int usage(String message) {
    err.writeln('$program: $message');
    err.writeln(usageFor(program));
    return cliUsageError;
  }

  try {
    switch (args) {
      case ['provider', 'list']:
        final settings = container.read(settingsProvider);
        if (settings.problem != null) {
          err.writeln('$program: ${settings.problem}');
        }
        final registry = container.read(llmRegistryProvider);
        final order = container.read(llmOrderProvider);
        final resolution = container.read(llmResolutionProvider);
        // Where an id stands in the preference order, and whether it is
        // the one answering (#62): `1*` is a first choice that answers.
        String markFor(String id) {
          final at = order.indexOf(id);
          return '${at < 0 ? ' ' : at + 1}'
              '${resolution.provider?.id == id ? '*' : ' '}';
        }

        for (final provider in registry.values) {
          final config = settings.provider(provider.id);
          final mark = markFor(provider.id);
          final key = credentialSuffix(
            container.read(credentialStatusProvider(provider.id)),
            config,
          );
          final where = switch ((config, provider)) {
            (null, OpenAiCompatibleProvider(:final origin)) =>
              'built-in @ $origin',
            (null, _) => 'built-in',
            (final c?, _) when c.endpoint == null => c.kind,
            (final c?, _) => '${c.kind} @ ${c.endpoint}',
          };
          final routing = switch (openRouterRoutingOf(provider)) {
            final r? => ' · ${r.label}',
            null => '',
          };
          // The two OpenAI kinds name their billing (#26).
          final billing = switch (provider) {
            ChatGptSubscriptionProvider() => ' · ChatGPT subscription',
            OpenAiResponsesProvider() => ' · OpenAI API, billed separately',
            _ => '',
          };
          final effort = switch (provider) {
            ConfiguredEffort(:final reasoningEffort) =>
              ' · effort ${reasoningEffort?.word ?? 'default'}',
            _ => '',
          };
          out.writeln(
            '$mark ${provider.id}  $where  (${provider.defaultModel}) · '
            '${provider.privacy.name}$billing$routing$effort$key',
          );
        }
        final misconfigured = container.read(misconfiguredLlmsProvider);
        for (final config in settings.providers) {
          if (registry.containsKey(config.id)) continue;
          final mark = markFor(config.id);
          final why = misconfigured[config.id];
          out.writeln(
            '$mark ${config.id}  ${config.kind}  — '
            '${why == null ? 'kind not available in this build' : misconfiguredNote(why)}',
          );
        }
        if (order.isEmpty) {
          out.writeln('   (no provider selected)');
        } else if (resolution.provider == null) {
          out.writeln('   ${noEligibleProviderError(resolution.skipped)}');
        } else if (resolution.isFallback) {
          out.writeln(
            '   answering: ${resolution.provider!.id}'
            '${fallbackSuffix(resolution)}',
          );
        }
        return cliOk;

      case ['provider', 'add', final id, ...final rest]:
        // An existing id is edited in place: only the options given
        // change, so a model tweak never drops the credential or what a
        // newer sai stored in the entry.
        final existing = container.read(settingsProvider).provider(id);
        // A built-in's id starts from the built-in (#23): kind, endpoint
        // and model as shipped, so one option changes one thing.
        final builtin = existing == null
            ? container.read(llmRegistryProvider)[id]
            : null;
        final seed = existing ?? (builtin == null ? null : configFor(builtin));
        String? kind = seed?.kind;
        String? endpoint = seed?.endpoint;
        String? model = seed?.defaultModel;
        LlmPrivacy? privacy = seed?.privacy;
        String? routing = seed?.routing;
        String? effort = seed?.reasoningEffort;
        bool? keyGiven;
        String? endpointGiven;
        String? modelGiven;
        String? routingGiven;
        String? effortGiven;
        LlmPrivacy? privacyGiven;
        for (var i = 0; i < rest.length; i++) {
          String value() {
            if (i + 1 >= rest.length) {
              throw _Usage('${rest[i]} needs a value');
            }
            return rest[++i];
          }

          switch (rest[i]) {
            case '--kind':
              kind = value();
            case '--endpoint':
              endpoint = endpointGiven = value();
            case '--model':
              model = modelGiven = value();
            case '--key':
              keyGiven = true;
            case '--no-key':
              keyGiven = false;
            case '--routing':
              routingGiven = value();
              if (!const {'recommended', 'exact'}.contains(routingGiven)) {
                throw _Usage(
                  '--routing takes recommended or exact, not $routingGiven',
                );
              }
            case '--privacy':
              final name = value();
              privacy = privacyGiven = LlmPrivacy.values.asNameMap()[name];
              if (privacy == null) {
                throw _Usage('--privacy takes local or cloud, not $name');
              }
            case '--effort':
              // The word goes through as typed; `default` is Model
              // default, the absent key (#26).
              effortGiven = value();
              effort = effortGiven == 'default' ? null : effortGiven;
            default:
              throw _Usage('unknown option ${rest[i]}');
          }
        }
        if (kind == null) throw _Usage('provider add needs --kind');
        // The key stays as the entry had it, or as the built-in ships it
        // while the entry keeps the built-in's kind — a built-in's
        // account is not carried into another kind unasked.
        var key =
            keyGiven ??
            (existing != null
                ? existing.credential != null
                : seed?.credential != null && kind == seed?.kind);
        if (kind == openRouterKind) {
          // OpenRouter (#24): one origin, cloud, keyed; the model is one
          // exact id, and the routing is said, never inferred. What an
          // entry changed to this kind brought along — an endpoint, a
          // local tag — is dropped; only the flags typed are refused.
          if (endpointGiven != null) {
            throw _Usage(
              'openrouter has a fixed endpoint; --endpoint does '
              'not apply',
            );
          }
          if (privacyGiven == LlmPrivacy.local) {
            throw _Usage(
              'openrouter is a cloud provider; --privacy local '
              'does not apply',
            );
          }
          if (keyGiven == false) {
            throw _Usage('openrouter needs a key; --no-key does not apply');
          }
          endpoint = null;
          privacy = LlmPrivacy.cloud;
          key = true;
          if (routingGiven == 'recommended') {
            if (modelGiven != null && modelGiven != openRouterPresetModel) {
              throw _Usage(
                'the recommended routing pins $openRouterPresetModel; '
                'leave --model out or use --routing exact',
              );
            }
            model = openRouterPresetModel;
            routing = OpenRouterRouting.deepinfraFp8.word;
          } else if (routingGiven == 'exact' || modelGiven != null) {
            routing = OpenRouterRouting.exact.word;
          }
          if (model == null) throw _Usage('provider add needs --model');
          final problem = openRouterModelProblem(model);
          if (problem != null) throw _Usage(problem);
        } else if (routingGiven != null) {
          throw _Usage('--routing applies to openrouter only');
        } else {
          // Routing is OpenRouter's word (settings-v0): another kind
          // carries none, whatever the entry had before.
          routing = null;
        }
        if (kind == openAiKind || kind == chatGptKind) {
          // The two OpenAI kinds (#26): one origin each, cloud, and the
          // billing said by the kind — a key for the API, the App
          // Server's own login for the plan. Only the flags typed are
          // refused; what an entry brought along is dropped.
          if (endpointGiven != null) {
            throw _Usage(
              '$kind has a fixed endpoint; --endpoint does not apply',
            );
          }
          if (privacyGiven == LlmPrivacy.local) {
            throw _Usage(
              '$kind is a cloud provider; --privacy local does not apply',
            );
          }
          endpoint = null;
          privacy = LlmPrivacy.cloud;
          if (kind == openAiKind) {
            if (keyGiven == false) {
              throw _Usage('openai needs a key; --no-key does not apply');
            }
            key = true;
            if (model == null) throw _Usage('provider add needs --model');
          } else {
            if (keyGiven == true) {
              throw _Usage(
                'chatgpt_subscription takes no key — the login is the App '
                "Server's own; sign in with: $program provider login $id",
              );
            }
            key = false;
          }
        } else if (effortGiven != null) {
          throw _Usage(
            '--effort applies to openai and chatgpt_subscription only; '
            'other kinds use: $program reasoning on|off',
          );
        } else {
          effort = null;
        }
        final ProviderConfig config;
        try {
          // What a new entry must satisfy beyond what a stored one must.
          if (endpoint != null) ProviderConfig.checkEndpointForEntry(endpoint);
          // The key binding survives only while the origin does; the
          // copy drops it otherwise (settings-v0, ADR 0009).
          final base = ProviderConfig(
            id: id,
            kind: kind,
            endpoint: existing?.endpoint,
            credential: existing?.credential,
            credentialOrigin: existing?.credentialOrigin,
            extra: existing?.extra ?? const {},
          );
          config = base.copyWith(
            endpoint: () => endpoint,
            defaultModel: () => model,
            credential: () => key
                ? (existing?.credential ?? ProviderConfig.credentialFor(id))
                : null,
            privacy: () => privacy,
            routing: () => routing,
            reasoningEffort: () => effort,
          );
        } on ArgumentError catch (e) {
          throw _Usage('${e.message}');
        }
        final notifier = container.read(settingsProvider.notifier);
        final hadKey =
            container.read(credentialStatusProvider(id)) ==
            CredentialStatus.set;
        final wasBound = existing?.keyBound ?? false;
        notifier.upsertProvider(config);
        out.writeln(
          '${existing != null ? 'updated' : 'added'} provider $id'
          '${builtin != null ? ' (over the built-in)' : ''}',
        );
        if (OpenRouterRouting.parse(config.routing) case final r?) {
          out.writeln(
            'routing: ${r.label}'
            '${r == OpenRouterRouting.exact ? ' — needs an endpoint that meets the privacy filters, zero retention above all' : ''}',
          );
        }
        if (kind == openAiKind || kind == chatGptKind) {
          out.writeln(
            'reasoning effort: ${config.reasoningEffort ?? 'Model default'}',
          );
        }
        if (hadKey && !key) {
          out.writeln(
            'its key is still in the Keychain; $program secret clear $id '
            'removes it',
          );
        }
        if (!container.read(llmFactoriesProvider).containsKey(kind)) {
          err.writeln(
            "$program: kind '$kind' is not available in this build; the "
            'provider is stored but cannot be used yet',
          );
        }
        final missing = container.read(misconfiguredLlmsProvider)[id];
        if (missing != null) {
          // A bare key can be added by its flag; a wrong value is fixed
          // by adding the entry again the way its kind wants it.
          final how = missing.contains(' ')
              ? 'add it again: $program provider add $id --kind $kind '
                    '--model <owner/name>'
              : 'add it with --${switch (missing) {
                  'default_model' => 'model',
                  'credential' => 'key',
                  _ => missing,
                }}';
          err.writeln(
            "$program: provider '$id' is ${misconfiguredNote(missing)}; $how",
          );
        }
        final stable = SaiIdentity.stable.tuiCommand;
        if (key && container.read(identityProvider).keychainService == null) {
          out.writeln(
            'this dev copy holds no credentials; the key is set in the '
            'stable one: $stable secret set $id',
          );
        } else if (key && wasBound && !config.keyBound) {
          out.writeln(
            'the endpoint moved; enter its key again: $program secret set $id',
          );
        } else if (key && !hadKey) {
          out.writeln('set its key with: $program secret set $id');
        }
        if (kind == chatGptKind) {
          out.writeln('sign in with: $program provider login $id');
        }
        return cliOk;

      case ['provider', 'reasoning', final id, ...final rest]:
        // The effort an OpenAI kind asks for (#26): shown, or set to a
        // word the backend reads as is; `default` leaves it to the model.
        final config = container.read(settingsProvider).provider(id);
        if (config == null) {
          err.writeln('$program: no provider $id is configured');
          return cliFailed;
        }
        if (config.kind != openAiKind && config.kind != chatGptKind) {
          err.writeln(
            "$program: provider '$id' is ${config.kind}, which keeps the "
            'reasoning on|off switch: $program reasoning on|off',
          );
          return cliFailed;
        }
        switch (rest) {
          case []:
            break;
          case [final word]:
            final effort = word.trim();
            if (effort.isEmpty) {
              throw _Usage('provider reasoning takes a word, or default');
            }
            container
                .read(settingsProvider.notifier)
                .upsertProvider(
                  config.copyWith(
                    reasoningEffort: () => effort == 'default' ? null : effort,
                  ),
                );
          default:
            throw _Usage('provider reasoning takes one word');
        }
        final now = container.read(settingsProvider).provider(id)!;
        out.writeln(
          '$id: reasoning effort ${now.reasoningEffort ?? 'Model default'}'
          '${now.kind == openAiKind ? ' (openai: which efforts a model takes depends on the model — ${openAiEffortWords.join(', ')})' : ''}',
        );
        return cliOk;

      case ['provider', 'account', final id]:
        final chat = _chatGpt(container, id, program, err);
        if (chat == null) return cliFailed;
        final (notifier, _) = chat;
        await notifier.refresh();
        final state = container.read(chatGptProvider);
        out.writeln(_accountLine(state));
        if (state.limits case final limits?) out.writeln(_planLine(limits));
        return state.failure == null ? cliOk : cliFailed;

      case ['provider', 'models', final id]:
        final config = container.read(settingsProvider).provider(id);
        final provider = container.read(llmRegistryProvider)[id];
        if (config?.kind == openAiKind || provider is OpenAiResponsesProvider) {
          if (provider is! OpenAiResponsesProvider) {
            err.writeln(
              "$program: provider '$id' cannot be built; repair it first",
            );
            return cliFailed;
          }
          final list = await fetchOpenAiCatalogue(provider);
          if (list.failure case final failure?) {
            err.writeln('$program: ${failure.message}');
            return cliFailed;
          }
          for (final m in list.models!) {
            out.writeln(m);
          }
          out.writeln(
            '${list.models!.length} models this key can reach — guidance '
            'only: the list does not say which take the Responses API or '
            'an effort (${openAiEffortWords.join(', ')})',
          );
          return cliOk;
        }
        final chat = _chatGpt(container, id, program, err);
        if (chat == null) return cliFailed;
        final (notifier, _) = chat;
        await notifier.refresh();
        final state = container.read(chatGptProvider);
        if (state.failure case final failure?) {
          err.writeln('$program: ${failure.message}');
          return cliFailed;
        }
        if (!state.signedIn) {
          err.writeln(
            '$program: ${CodexText.signedOut}: $program provider login $id',
          );
          return cliFailed;
        }
        for (final m in state.models ?? const <CodexModel>[]) {
          out.writeln(
            '${m.id}  ${m.displayName}${m.isDefault ? ' (default)' : ''} · '
            'default effort ${m.defaultEffort ?? 'unspecified'} · efforts: '
            '${m.supportedEfforts.isEmpty ? 'none advertised' : m.supportedEfforts.map((o) => o.effort.word).join(', ')}',
          );
        }
        return cliOk;

      case ['provider', 'login', final id, ...final rest]:
        final deviceCode = switch (rest) {
          [] => false,
          ['--device-code'] => true,
          _ => throw _Usage('provider login takes only --device-code'),
        };
        final chat = _chatGpt(container, id, program, err);
        if (chat == null) return cliFailed;
        final (notifier, runtime) = chat;
        final ChatGptLogin login;
        try {
          login = await notifier.signIn(deviceCode: deviceCode);
        } on CodexException catch (e) {
          err.writeln('$program: ${e.text}');
          return cliFailed;
        }
        // Public values only: the URL to open, the code to type. No
        // token ever comes this way, and the browser is the person's to
        // open (the terminal spawns nothing).
        if (login.isDeviceCode) {
          out.writeln(
            'open ${login.verificationUrl} and enter the code ${login.userCode}',
          );
        } else {
          out.writeln('open this URL in your browser to sign in:');
          out.writeln(login.authUrl);
        }
        out.writeln('waiting for the sign-in to finish (Ctrl-C cancels)…');
        final done = Completer<bool>();
        final sub = runtime.loginCompleted.listen((event) {
          if (event.loginId != null && event.loginId != login.loginId) return;
          if (!done.isCompleted) done.complete(event.success);
        });
        final interrupt = ProcessSignal.sigint.watch().listen((_) async {
          await notifier.cancelSignIn();
          if (!done.isCompleted) done.complete(false);
        });
        final bool success;
        try {
          success = await done.future;
        } finally {
          await sub.cancel();
          await interrupt.cancel();
        }
        if (!success) {
          err.writeln('$program: ${CodexText.loginFailed}');
          return cliFailed;
        }
        await notifier.refresh();
        out.writeln(_accountLine(container.read(chatGptProvider)));
        return cliOk;

      case ['provider', 'logout', final id]:
        final chat = _chatGpt(container, id, program, err);
        if (chat == null) return cliFailed;
        final (notifier, _) = chat;
        try {
          await notifier.signOut();
          await notifier.done;
        } on CodexException catch (e) {
          err.writeln('$program: ${e.text}');
          return cliFailed;
        }
        out.writeln(
          'signed out of ChatGPT; ${_accountLine(container.read(chatGptProvider))}',
        );
        return cliOk;

      case ['provider', 'remove', final id]:
        final settings = container.read(settingsProvider);
        if (settings.provider(id) == null) {
          err.writeln("$program: no configured provider '$id'");
          return cliFailed;
        }
        final hadKey =
            container.read(credentialStatusProvider(id)) ==
            CredentialStatus.set;
        container.read(settingsProvider.notifier).removeProvider(id);
        out.writeln('removed provider $id');
        if (hadKey) {
          out.writeln(
            'its key is still in the Keychain; $program secret clear $id '
            'removes it',
          );
        }
        return cliOk;

      case ['provider', 'use', final id]:
        final notifier = container.read(settingsProvider.notifier);
        if (id == 'none') {
          notifier.selectLlm(null);
          out.writeln('no provider selected');
          return cliOk;
        }
        if (!container.read(llmRegistryProvider).containsKey(id)) {
          err.writeln("$program: provider '$id' is not available");
          return cliFailed;
        }
        notifier.selectLlm(id);
        out.writeln(container.read(llmStatusProvider));
        // Only when there is a chain to say: a single choice prints the
        // one line it always did.
        if (container.read(llmOrderProvider).length > 1) {
          out.writeln(_orderLine(container));
        }
        final warning = container.read(activeLlmWarningProvider);
        if (warning != null) {
          out.writeln('$warning: $program privacy share-tasks on');
        }
        return cliOk;

      case ['provider', 'order']:
        out.writeln(_orderLine(container));
        return cliOk;

      case ['provider', 'order', ...final ids]:
        final registry = container.read(llmRegistryProvider);
        final seen = <String>{};
        for (final id in ids) {
          if (!registry.containsKey(id)) {
            err.writeln("$program: provider '$id' is not available");
            return cliFailed;
          }
          if (!seen.add(id)) {
            throw _Usage('provider order names $id twice');
          }
        }
        container.read(settingsProvider.notifier).setLlmOrder(ids);
        out.writeln(_orderLine(container));
        out.writeln(container.read(llmStatusProvider));
        return cliOk;

      case ['privacy']:
        out.writeln(privacyLine(container.read(privacyPolicyProvider)));
        return cliOk;

      case ['privacy', 'share-tasks', final position]:
        final share = switch (position) {
          'on' => true,
          'off' => false,
          _ => throw _Usage('share-tasks takes on or off, not $position'),
        };
        container.read(settingsProvider.notifier).setShareTasksWithCloud(share);
        out.writeln(privacyLine(container.read(privacyPolicyProvider)));
        final warning = container.read(activeLlmWarningProvider);
        if (warning != null) out.writeln(warning);
        return cliOk;

      case ['reasoning']:
        out.writeln(reasoningLine(container.read(reasoningProvider)));
        return cliOk;

      case ['reasoning', final position]:
        final show = switch (position) {
          'on' => true,
          'off' => false,
          _ => throw _Usage('reasoning takes on or off, not $position'),
        };
        container.read(settingsProvider.notifier).setReasoning(show);
        out.writeln(reasoningLine(container.read(reasoningProvider)));
        final active = container.read(firstChoiceLlmProvider);
        if (active != null && active is ConfiguredEffort) {
          out.writeln(
            '${active.id} carries its own reasoning effort; the switch is '
            'for the other providers. `$program provider reasoning '
            '${active.id} <word>` sets it.',
          );
        }
        return cliOk;

      case ['finished-tasks']:
        out.writeln(
          finishedTasksLine(container.read(finishedTaskVisibilityProvider)),
        );
        return cliOk;

      case ['finished-tasks', final word]:
        final visibility = switch (word) {
          'end-of-day' => FinishedTaskVisibility.endOfDay,
          'immediate' => FinishedTaskVisibility.immediate,
          _ => throw _Usage(
            'finished-tasks takes end-of-day or immediate, not $word',
          ),
        };
        container
            .read(settingsProvider.notifier)
            .setFinishedTaskVisibility(visibility);
        out.writeln(
          finishedTasksLine(container.read(finishedTaskVisibilityProvider)),
        );
        return cliOk;

      case ['usage', ...final rest]:
        final day = switch (rest) {
          [] => container.read(todayProvider),
          ['--day'] => throw _Usage('--day needs a day (YYYY-MM-DD)'),
          ['--day', final word] =>
            CalendarDate.tryParse(word) ??
                (throw _Usage('--day takes a day as YYYY-MM-DD')),
          _ => throw _Usage('usage takes only --day YYYY-MM-DD'),
        };
        // An unlistened future provider is disposed mid-load; hold it.
        final sub = container.listen(dailyUsageProvider, (_, _) {});
        final List<DailyUsage> rows;
        try {
          rows = (await container.read(dailyUsageProvider.future)).onDay(day);
        } finally {
          sub.close();
        }
        if (rows.isEmpty) {
          out.writeln('no calls on $day');
          return cliOk;
        }
        for (final row in rows) {
          out.writeln(usageLine(row));
        }
        return cliOk;

      case ['secret', final verb, final id]
          when const {'set', 'clear', 'status'}.contains(verb):
        if (!ProviderConfig.idForm.hasMatch(id)) {
          throw _Usage("'$id' is not a provider id");
        }
        // Dev holds no credentials (#95, ADR 0019): nothing to set, ask
        // or clear, and no Keychain is ever opened for it.
        if (container.read(identityProvider).keychainService == null) {
          err.writeln(
            '$program holds no credentials (ADR 0019); '
            'use ${SaiIdentity.stable.tuiCommand}',
          );
          return cliFailed;
        }
        final config = container.read(settingsProvider).provider(id);
        final credentials = container.read(credentialsProvider.notifier);
        if (verb == 'set') {
          // Storing needs a provider that will use the key: a configured
          // one, or a built-in that ships taking one (OpenRouter, #24),
          // which the store configures as shipped first.
          final builtin = config == null
              ? container.read(llmRegistryProvider)[id]
              : null;
          final takesKey =
              config?.credential != null ||
              (builtin != null && configFor(builtin)?.credential != null);
          if (config == null && !takesKey) {
            err.writeln("$program: no configured provider '$id'");
            return cliFailed;
          }
          if (!takesKey) {
            err.writeln(
              "$program: provider '$id' takes no key (add it with --key)",
            );
            return cliFailed;
          }
          final value = await readSecret('API key for $id: ');
          if (value == null || value.isEmpty) {
            err.writeln('$program: no key given; nothing changed');
            return cliFailed;
          }
          credentials.set(id, value);
          out.writeln(
            'key for $id stored in the Keychain'
            '${config == null ? ' ($id configured as shipped)' : ''}',
          );
          return cliOk;
        }
        // Clearing and asking work on the account alone, so a key left
        // behind by a removed or re-keyed provider can still be revoked.
        final account = config?.credential ?? ProviderConfig.credentialFor(id);
        switch (verb) {
          case 'clear':
            final gone = credentials.clearAccount(account);
            out.writeln(gone ? 'key for $id removed' : 'no key for $id');
          case 'status':
            out.writeln(switch (credentials.statusOf(account)) {
              CredentialStatus.set => 'set',
              CredentialStatus.missing => 'missing',
              CredentialStatus.unavailable => 'keychain unavailable',
              CredentialStatus.absent => 'no credentials in dev',
              CredentialStatus.none => 'none',
            });
        }
        return cliOk;

      case ['things', 'import', ...final rest]:
        var dryRun = false;
        var openOnly = false;
        var skipRepeatHistory = false;
        CalendarDate? logbookSince;
        String? explicit;
        for (var i = 0; i < rest.length; i++) {
          switch (rest[i]) {
            case '--dry-run':
              dryRun = true;
            case '--open-only':
              openOnly = true;
            case '--skip-repeat-history':
              skipRepeatHistory = true;
            case '--logbook-since':
              if (i + 1 >= rest.length) {
                throw _Usage('--logbook-since needs a day (YYYY-MM-DD)');
              }
              logbookSince = CalendarDate.tryParse(rest[++i]);
              if (logbookSince == null) {
                throw _Usage('--logbook-since takes a day as YYYY-MM-DD');
              }
            case '--db':
              if (i + 1 >= rest.length) throw _Usage('--db needs a path');
              explicit = rest[++i];
            default:
              throw _Usage('unknown option: ${rest[i]}');
          }
        }
        final environment = container.read(environmentProvider);
        final String? path;
        try {
          path =
              explicit ??
              locateThingsDatabase(
                environment: environment,
                home: environment['HOME'] ?? '',
              );
        } on ThingsAmbiguousDatabase catch (e) {
          err.writeln(
            '$program: ${e.count} Things databases found under the group '
            'container; pass --db <main.sqlite> to say which one',
          );
          return cliFailed;
        }
        if (path == null) {
          err.writeln(
            '$program: no Things 3 database found; pass --db <main.sqlite> '
            'or set $thingsDatabaseEnv',
          );
          return cliFailed;
        }
        final ThingsSnapshot snapshot;
        final started = DateTime.now();
        try {
          final db = ThingsDatabase.snapshot(path);
          try {
            snapshot = db.read();
          } finally {
            db.dispose();
          }
        } on FileSystemException {
          err.writeln('$program: cannot read the Things database at $path');
          return cliFailed;
        } on ThingsSchemaException catch (e) {
          err.writeln('$program: not a Things 3 database (${e.message})');
          return cliFailed;
        }
        await container.read(tasksProvider.future);
        final store = container.read(tasksProvider.notifier).store;
        final ThingsImportResult result;
        try {
          result = await importThings(
            snapshot,
            store: store,
            now: DateTime.now().toUtc(),
            dryRun: dryRun,
            options: ThingsImportOptions(
              openOnly: openOnly,
              skipRepeatHistory: skipRepeatHistory,
              logbookSince: logbookSince,
            ),
          );
        } on ThingsImportException catch (e) {
          err.writeln('$program: import stopped: $e');
          return cliFailed;
        }
        out.writeln(
          'things import${dryRun ? ' (dry run)' : ''}: $path '
          '(mapping verified against Things $thingsVerifiedVersion)',
        );
        if (dryRun) {
          for (final op in result.plan.ops) {
            out.writeln(op.describe());
          }
        }
        for (final line in result.report.render()) {
          out.writeln(line);
        }
        final elapsed = DateTime.now().difference(started);
        out.writeln(
          result.plan.isEmpty
              ? result.report.unsupported.isEmpty
                    ? 'nothing to do — sai already matches Things'
                    : 'nothing to do — sai already holds everything '
                          'this run would import; the rows above stay behind'
              : dryRun
              ? '${result.plan.length} operations would run; nothing written'
              : '${result.plan.length} operations, '
                    '${result.eventsAppended} events appended in '
                    '${elapsed.inMilliseconds} ms',
        );
        return cliOk;

      default:
        return usage('unknown command: ${args.join(' ')}');
    }
  } on _Usage catch (e) {
    return usage(e.message);
  } on SecretStoreException catch (e) {
    err.writeln('$program: $e');
    return cliFailed;
  } on StateError catch (e) {
    err.writeln('$program: ${e.message}');
    return cliFailed;
  }
}

/// The ChatGPT notifier and runtime for [id], or null after saying why
/// not: no such entry, another kind, or — the dev copy (#95) — no
/// runtime at all, said before any spawn.
(ChatGptNotifier, AppServerRuntime)? _chatGpt(
  ProviderContainer container,
  String id,
  String program,
  StringSink err,
) {
  final config = container.read(settingsProvider).provider(id);
  if (config == null) {
    err.writeln(
      '$program: no provider $id is configured; add it with: $program '
      'provider add $id --kind chatgpt_subscription',
    );
    return null;
  }
  if (config.kind != chatGptKind) {
    err.writeln(
      "$program: provider '$id' is ${config.kind}, not chatgpt_subscription",
    );
    return null;
  }
  final runtime = container.read(appServerRuntimeProvider);
  if (runtime == null) {
    err.writeln(
      '$program: ${CodexText.devRefused}: ${SaiIdentity.stable.tuiCommand}',
    );
    return null;
  }
  return (container.read(chatGptProvider.notifier), runtime);
}

/// What `provider account` says: signed in and the plan, or not — the
/// email is shown here and nowhere else.
String _accountLine(ChatGptState state) {
  if (state.failure case final failure?) return failure.message;
  final account = state.account;
  if (account == null) return 'account not read';
  return switch (account.type) {
    CodexAccountType.chatgpt =>
      'signed in to ChatGPT'
          '${account.email == null ? '' : ' as ${account.email}'}'
          '${account.planType == null ? '' : ' · ${account.planType} plan'}',
    CodexAccountType.none => 'not signed in to ChatGPT',
    _ => CodexText.wrongAuth,
  };
}

/// The plan's usage as availability, never money.
String _planLine(CodexRateLimits limits) {
  String window(String name, CodexRateWindow w) =>
      '$name ${w.usedPercent}% used'
      '${w.resetsAt == null ? '' : ', resets ${w.resetsAt!.toLocal().toString().substring(0, 16)}'}';
  final parts = [
    if (limits.primary case final p?) window('plan usage:', p),
    if (limits.secondary case final s?) window('weekly', s),
  ];
  if (parts.isEmpty) return 'plan usage: not reported';
  return '${parts.join(' · ')}${limits.limitReached ? ' · limit reached' : ''}';
}

/// The preference order as one line (#62): what is tried, in order.
String _orderLine(ProviderContainer container) {
  final order = container.read(llmOrderProvider);
  return order.isEmpty ? 'order: none' : 'order: ${order.join(', ')}';
}

final class _Usage implements Exception {
  _Usage(this.message);

  final String message;
}
