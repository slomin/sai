import 'dart:io';

import 'package:path/path.dart' as p;

import '../../archive/archive_root.dart';
import '../../identity.dart';
import '../../process/posix.dart';
import '../../settings/provider_config.dart';
import '../call.dart';
import '../provider.dart';
import 'provider.dart';
import 'runtime.dart';
import 'text.dart';

/// The `chatgpt_subscription` kind (#26, ADR 0013): a ChatGPT plan, used
/// through OpenAI's own Codex App Server running as sai's child. The
/// login belongs to that runtime — sai holds no token and the entry
/// names no credential. Cloud by nature; the model is chosen from what
/// the runtime lists, so an entry may stand without one until it is.
const chatGptKind = 'chatgpt_subscription';

/// Why [config] cannot be built as a `chatgpt_subscription` provider, or
/// null when it can. Everything here is a phrase: the kind has nothing a
/// bare flag could add — no endpoint, no key, no routing — and the model
/// is chosen in the clients from the live list, not typed blind.
String? chatGptProblem(ProviderConfig config) {
  if (config.endpoint != null) {
    return 'carrying an endpoint, but chatgpt_subscription has none';
  }
  if (config.privacy == LlmPrivacy.local) {
    return 'tagged local, but chatgpt_subscription is a cloud provider';
  }
  if (config.routing != null) {
    return 'carrying a routing word, which only openrouter takes';
  }
  if (config.credential != null) {
    return 'naming a key, but the ChatGPT login lives in the App Server, '
        'not the Keychain';
  }
  return null;
}

/// The environment variable that moves the credential home (#26) — for a
/// scratch smoke, the way `SAI_ARCHIVE_ROOT` moves the archive. The
/// value must be absolute and must not be the person's own `~/.codex`:
/// that home is the Codex CLI's token family, and sharing it is the
/// refresh race ADR 0013 exists to avoid.
const codexHomeVariable = 'SAI_CODEX_HOME';

/// The directory under the data directory the App Server owns:
/// `~/Library/Application Support/sai/codex` for stable. Never moved
/// casually — Codex derives its Keychain account from the canonical
/// path, so a moved home is a fresh login.
const codexHomeDirName = 'codex';

/// sai's own `config.toml` for the runtime, written before every spawn
/// and compared byte for byte: the credential in the Keychain rather
/// than a plaintext `auth.json`; ChatGPT the only way to sign in; no
/// history on disk; no MCP servers; no web search; no update check.
/// Anything the person's own `~/.codex/config.toml` says is never read —
/// the runtime sees this home and nothing else.
const codexConfigToml = '''
# Written by sai (#26, ADR 0013). Edits are overwritten on the next start.
cli_auth_credentials_store = "keyring"
forced_login_method = "chatgpt"
check_for_update_on_startup = false
web_search = "disabled"

[history]
persistence = "none"

[mcp_servers]
''';

/// Per-thread configuration overrides sent with `thread/start`, saying
/// again what the file says, for the settings a thread can carry.
const codexThreadConfig = <String, Object?>{
  'web_search': 'disabled',
  'mcp_servers': <String, Object?>{},
};

/// Where the runtime's home is for [identity] under [environment], or
/// null for the dev flavor (#95): a dev copy never opens a Keychain, so
/// it never runs a runtime whose credential lives in one. Throws
/// [ArgumentError] for an override that is not absolute or that names
/// the Codex CLI's own home.
Directory? resolveCodexHome({
  required Map<String, String> environment,
  required String operatingSystem,
  required SaiIdentity identity,
}) {
  if (identity.isDev) return null;
  final override = environment[codexHomeVariable];
  if (override != null && override.isNotEmpty) {
    if (!p.isAbsolute(override)) {
      throw ArgumentError('$codexHomeVariable must be an absolute path');
    }
    final home = environment['HOME'];
    if (home != null &&
        p.equals(p.normalize(override), p.join(home, '.codex'))) {
      throw ArgumentError(
        '$codexHomeVariable must not be ~/.codex, the Codex CLI\'s own home',
      );
    }
    return Directory(p.normalize(override));
  }
  return Directory(
    p.join(
      resolveDataDir(
        environment: environment,
        operatingSystem: operatingSystem,
        identity: identity,
        what: 'the ChatGPT credential home',
      ).path,
      codexHomeDirName,
    ),
  );
}

/// The user's `~/Library/Keychains`, which the sandbox profile opens for
/// the runtime's own credential item.
Directory? resolveKeychainsDir(Map<String, String> environment) {
  final home = environment['HOME'];
  if (home == null || home.isEmpty) return null;
  return Directory(p.join(home, 'Library', 'Keychains'));
}

/// Makes [home] exact: created if missing, no symlink in its own place or
/// its parent's, mode 0700, `config.toml` as [codexConfigToml] to the
/// byte (written to a sibling and renamed, mode 0600). Anything that
/// cannot be made so is a [FileSystemException] — the runtime is not
/// started against a home sai does not fully own. Nothing here reads or
/// writes `auth.json`: the credential is the runtime's, in the Keychain.
Directory prepareCodexHome(Directory home) {
  final parent = home.parent;
  if (!parent.existsSync()) parent.createSync(recursive: true);
  if (_isLink(parent) || _isLink(home)) {
    throw FileSystemException('symlink in the credential home path', home.path);
  }
  if (!home.existsSync()) home.createSync();
  _restrict(home, directory: true);
  final config = File(p.join(home.path, 'config.toml'));
  if (_isLink(config)) {
    throw FileSystemException('config.toml is a symlink', config.path);
  }
  final current = config.existsSync() ? config.readAsStringSync() : null;
  if (current != codexConfigToml) {
    final temp = File(p.join(home.path, '.config.toml.$pid.tmp'));
    temp.writeAsStringSync(codexConfigToml, flush: true);
    _restrict(temp, directory: false);
    temp.renameSync(config.path);
  }
  _restrict(config, directory: false);
  if (config.readAsStringSync() != codexConfigToml) {
    throw FileSystemException('config.toml could not be written', config.path);
  }
  return home;
}

/// A directory of sai's that the Seatbelt profile opens read-write for
/// the child — its temp root, the scratch root — made 0700 on every
/// start and refused when a symlink stands in its place or its parent's
/// (#26): what the profile grants must resolve to sai's own directory.
Directory preparePrivateDir(Directory dir) {
  final parent = dir.parent;
  if (!parent.existsSync()) parent.createSync(recursive: true);
  if (_isLink(parent) || _isLink(dir)) {
    throw FileSystemException('symlink in a private directory path', dir.path);
  }
  if (!dir.existsSync()) dir.createSync();
  _restrict(dir, directory: true);
  return dir;
}

bool _isLink(FileSystemEntity entity) =>
    FileSystemEntity.typeSync(entity.path, followLinks: false) ==
    FileSystemEntityType.link;

/// 0700 for a directory, 0600 for a file — the group and others see
/// nothing of the credential home. Asked of the C library, since
/// `dart:io` has no chmod; refused as a [FileSystemException] when the
/// mode did not take.
void _restrict(FileSystemEntity entity, {required bool directory}) {
  final mode = directory ? 0x1c0 : 0x180;
  if (!posixChmod(entity.path, mode)) {
    throw FileSystemException('could not restrict the mode', entity.path);
  }
  if (codexHomeMode(entity) != mode) {
    throw FileSystemException('the mode did not take', entity.path);
  }
}

/// The mode bits of [entity], for the tests and the smoke to assert.
int codexHomeMode(FileSystemEntity entity) => entity.statSync().mode & 0x1ff;

/// The `chatgpt_subscription` kind. Throws [ArgumentError] when
/// [chatGptProblem] names one. With no [runtime] — the dev flavor, a build
/// without the sidecar — the provider refuses every call in fixed words
/// before anything is spawned.
LlmProvider chatGptFactory(
  ProviderConfig config, {
  required AppServerRuntime? runtime,
  String noRuntimeText = CodexText.devRefused,
}) {
  final problem = chatGptProblem(config);
  if (problem != null) {
    throw ArgumentError(
      'chatgpt_subscription: its $problem is missing or wrong',
    );
  }
  return ChatGptSubscriptionProvider(
    id: config.id,
    installedRuntime: runtime,
    defaultModel: config.defaultModel,
    reasoningEffort: ReasoningEffort.parse(config.reasoningEffort),
    noRuntimeText: noRuntimeText,
  );
}
