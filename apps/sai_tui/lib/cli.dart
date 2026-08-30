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
       sai_tui provider remove <id>
       sai_tui provider use <id|none>
       sai_tui privacy               show the cloud-sharing switch
       sai_tui privacy share-tasks on|off
       sai_tui reasoning [on|off]    let the model think before answering
       sai_tui finished-tasks [end-of-day|immediate]
                                    when a finished task leaves its list
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
        for (final provider in registry.values) {
          final config = settings.provider(provider.id);
          final mark = settings.llm == provider.id ? '*' : ' ';
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
          out.writeln(
            '$mark ${provider.id}  $where  (${provider.defaultModel}) · '
            '${provider.privacy.name}$key',
          );
        }
        final misconfigured = container.read(misconfiguredLlmsProvider);
        for (final config in settings.providers) {
          if (registry.containsKey(config.id)) continue;
          final mark = settings.llm == config.id ? '*' : ' ';
          final why = misconfigured[config.id];
          out.writeln(
            '$mark ${config.id}  ${config.kind}  — '
            '${why == null ? 'kind not available in this build' : misconfiguredNote(why)}',
          );
        }
        if (settings.llm == null) out.writeln('  (no provider selected)');
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
        String? kind =
            existing?.kind ??
            switch (builtin) {
              OpenAiCompatibleProvider() => 'openai_compatible',
              FakeLlmProvider() => 'fake',
              _ => null,
            };
        String? endpoint =
            existing?.endpoint ??
            (builtin is OpenAiCompatibleProvider
                ? builtin.endpoint.toString()
                : null);
        String? model = existing?.defaultModel ?? builtin?.defaultModel;
        LlmPrivacy? privacy = existing?.privacy ?? builtin?.privacy;
        var key = existing?.credential != null;
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
              endpoint = value();
            case '--model':
              model = value();
            case '--key':
              key = true;
            case '--no-key':
              key = false;
            case '--privacy':
              final name = value();
              privacy = LlmPrivacy.values.asNameMap()[name];
              if (privacy == null) {
                throw _Usage('--privacy takes local or cloud, not $name');
              }
            default:
              throw _Usage('unknown option ${rest[i]}');
          }
        }
        if (kind == null) throw _Usage('provider add needs --kind');
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
          );
        } on ArgumentError catch (e) {
          throw _Usage('${e.message}');
        }
        final notifier = container.read(settingsProvider.notifier);
        final hadKey =
            existing != null &&
            container.read(credentialStatusProvider(id)) ==
                CredentialStatus.set;
        final wasBound = existing?.keyBound ?? false;
        notifier.upsertProvider(config);
        out.writeln(
          '${existing != null ? 'updated' : 'added'} provider $id'
          '${builtin != null ? ' (over the built-in)' : ''}',
        );
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
          err.writeln(
            "$program: provider '$id' is ${misconfiguredNote(missing)}; add it "
            'with --${missing == 'default_model' ? 'model' : missing}',
          );
        }
        if (key && wasBound && !config.keyBound) {
          out.writeln(
            'the endpoint moved; enter its key again: $program secret set $id',
          );
        } else if (key && !hadKey) {
          out.writeln('set its key with: $program secret set $id');
        }
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
        final warning = container.read(activeLlmWarningProvider);
        if (warning != null) {
          out.writeln('$warning: $program privacy share-tasks on');
        }
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
          // Storing needs a provider that will use the key.
          if (config == null) {
            err.writeln("$program: no configured provider '$id'");
            return cliFailed;
          }
          if (config.credential == null) {
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
          out.writeln('key for $id stored in the Keychain');
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

final class _Usage implements Exception {
  _Usage(this.message);

  final String message;
}
