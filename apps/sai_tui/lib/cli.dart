import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';

/// What `sai_tui <command>` prints for `help` and for a usage error.
const cliUsage = '''
usage: sai_tui                       open the terminal client
       sai_tui provider list
       sai_tui provider add <id> --kind <kind> [--endpoint <url>]
                                    [--model <name>] [--key]
       sai_tui provider remove <id>
       sai_tui provider use <id|none>
       sai_tui secret set <id>       read the key from a hidden prompt
                                    (or from stdin when piped)
       sai_tui secret clear <id>
       sai_tui secret status <id>
       sai_tui help

Provider settings go to settings.json; keys go to the Keychain and are
never written to a file or printed. --key files the key under
provider:<id> (docs/settings/settings-v0.md).''';

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
  required String? Function(String prompt) readSecret,
}) async {
  if (args.isEmpty || args.first == 'help' || args.first == '--help') {
    out.writeln(cliUsage);
    return cliOk;
  }
  int usage(String message) {
    err.writeln('sai_tui: $message');
    err.writeln(cliUsage);
    return cliUsageError;
  }

  try {
    switch (args) {
      case ['provider', 'list']:
        final settings = container.read(settingsProvider);
        if (settings.problem != null) {
          err.writeln('sai_tui: ${settings.problem}');
        }
        final registry = container.read(llmRegistryProvider);
        for (final provider in registry.values) {
          final config = settings.provider(provider.id);
          final mark = settings.llm == provider.id ? '*' : ' ';
          final key = switch (container.read(
            credentialStatusProvider(provider.id),
          )) {
            CredentialStatus.none => '',
            CredentialStatus.set => ' · key set',
            CredentialStatus.missing => ' · no key',
            CredentialStatus.unavailable => ' · keychain unavailable',
          };
          final where = config?.endpoint == null
              ? (config == null ? 'built-in' : config.kind)
              : '${config!.kind} @ ${config.endpoint}';
          out.writeln(
            '$mark ${provider.id}  $where  (${provider.defaultModel})$key',
          );
        }
        for (final config in settings.providers) {
          if (registry.containsKey(config.id)) continue;
          final mark = settings.llm == config.id ? '*' : ' ';
          out.writeln(
            "$mark ${config.id}  ${config.kind}  — kind not available in "
            'this build',
          );
        }
        if (settings.llm == null) out.writeln('  (no provider selected)');
        return cliOk;

      case ['provider', 'add', final id, ...final rest]:
        String? kind;
        String? endpoint;
        String? model;
        var key = false;
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
            default:
              throw _Usage('unknown option ${rest[i]}');
          }
        }
        if (kind == null) throw _Usage('provider add needs --kind');
        final ProviderConfig config;
        try {
          config = ProviderConfig(
            id: id,
            kind: kind,
            endpoint: endpoint,
            defaultModel: model,
            credential: key ? ProviderConfig.credentialFor(id) : null,
          );
        } on ArgumentError catch (e) {
          throw _Usage('${e.message}');
        }
        final notifier = container.read(settingsProvider.notifier);
        final replaced = container.read(settingsProvider).provider(id) != null;
        notifier.upsertProvider(config);
        out.writeln('${replaced ? 'updated' : 'added'} provider $id');
        if (!container.read(llmFactoriesProvider).containsKey(kind)) {
          err.writeln(
            "sai_tui: kind '$kind' is not available in this build; the "
            'provider is stored but cannot be used yet',
          );
        }
        if (key) {
          out.writeln('set its key with: sai_tui secret set $id');
        }
        return cliOk;

      case ['provider', 'remove', final id]:
        final settings = container.read(settingsProvider);
        if (settings.provider(id) == null) {
          err.writeln("sai_tui: no configured provider '$id'");
          return cliFailed;
        }
        final hadKey =
            container.read(credentialStatusProvider(id)) ==
            CredentialStatus.set;
        container.read(settingsProvider.notifier).removeProvider(id);
        out.writeln('removed provider $id');
        if (hadKey) {
          out.writeln(
            'its key is still in the Keychain; sai_tui secret clear $id '
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
          err.writeln("sai_tui: provider '$id' is not available");
          return cliFailed;
        }
        notifier.selectLlm(id);
        out.writeln(container.read(llmStatusProvider));
        return cliOk;

      case ['secret', final verb, final id]
          when const {'set', 'clear', 'status'}.contains(verb):
        final config = container.read(settingsProvider).provider(id);
        if (config == null) {
          err.writeln("sai_tui: no configured provider '$id'");
          return cliFailed;
        }
        if (config.credential == null) {
          err.writeln(
            "sai_tui: provider '$id' takes no key (add it with --key)",
          );
          return cliFailed;
        }
        final credentials = container.read(credentialsProvider.notifier);
        switch (verb) {
          case 'set':
            final value = readSecret('API key for $id: ');
            if (value == null || value.isEmpty) {
              err.writeln('sai_tui: no key given; nothing changed');
              return cliFailed;
            }
            credentials.set(id, value);
            out.writeln('key for $id stored in the Keychain');
          case 'clear':
            final gone = credentials.clear(id);
            out.writeln(gone ? 'key for $id removed' : 'no key for $id');
          case 'status':
            out.writeln(switch (container.read(credentialStatusProvider(id))) {
              CredentialStatus.set => 'set',
              CredentialStatus.missing => 'missing',
              CredentialStatus.unavailable => 'keychain unavailable',
              CredentialStatus.none => 'none',
            });
        }
        return cliOk;

      default:
        return usage('unknown command: ${args.join(' ')}');
    }
  } on _Usage catch (e) {
    return usage(e.message);
  } on SecretStoreException catch (e) {
    err.writeln('sai_tui: $e');
    return cliFailed;
  } on StateError catch (e) {
    err.writeln('sai_tui: ${e.message}');
    return cliFailed;
  }
}

final class _Usage implements Exception {
  _Usage(this.message);

  final String message;
}
