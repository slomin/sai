import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('sai_codex_home'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('resolveCodexHome', () {
    test('is <data dir>/codex for stable, and nothing for dev', () {
      final env = {'HOME': tmp.path};
      final home = resolveCodexHome(
        environment: env,
        operatingSystem: 'macos',
        identity: SaiIdentity.stable,
      );
      expect(
        home!.path,
        p.join(tmp.path, 'Library', 'Application Support', 'sai', 'codex'),
      );
      expect(
        resolveCodexHome(
          environment: env,
          operatingSystem: 'macos',
          identity: SaiIdentity.dev,
        ),
        isNull,
      );
    });

    test(
      'SAI_CODEX_HOME moves it, but never onto ~/.codex or a relative path',
      () {
        final env = {
          'HOME': tmp.path,
          codexHomeVariable: '${tmp.path}/scratch/codex',
        };
        expect(
          resolveCodexHome(
            environment: env,
            operatingSystem: 'macos',
            identity: SaiIdentity.stable,
          )!.path,
          '${tmp.path}/scratch/codex',
        );
        expect(
          () => resolveCodexHome(
            environment: {
              'HOME': tmp.path,
              codexHomeVariable: 'relative/codex',
            },
            operatingSystem: 'macos',
            identity: SaiIdentity.stable,
          ),
          throwsArgumentError,
        );
        expect(
          () => resolveCodexHome(
            environment: {
              'HOME': tmp.path,
              codexHomeVariable: '${tmp.path}/.codex',
            },
            operatingSystem: 'macos',
            identity: SaiIdentity.stable,
          ),
          throwsArgumentError,
        );
        expect(
          () => resolveCodexHome(
            environment: {
              'HOME': tmp.path,
              codexHomeVariable: '${tmp.path}/x/../.codex',
            },
            operatingSystem: 'macos',
            identity: SaiIdentity.stable,
          ),
          throwsArgumentError,
        );
      },
    );
  });

  group('prepareCodexHome', () {
    test('creates the home 0700 with the exact config.toml 0600', () {
      final home = Directory(p.join(tmp.path, 'data', 'codex'));
      final prepared = prepareCodexHome(home);
      expect(prepared.existsSync(), isTrue);
      expect(codexHomeMode(prepared), 0x1c0);
      final config = File(p.join(home.path, 'config.toml'));
      expect(config.readAsStringSync(), codexConfigToml);
      expect(codexHomeMode(config), 0x180);
      // No auth.json, ever, from sai's side.
      expect(File(p.join(home.path, 'auth.json')).existsSync(), isFalse);
      expect(home.listSync().map((e) => p.basename(e.path)), ['config.toml']);
    });

    test('rewrites a config.toml that drifted, atomically', () {
      final home = Directory(p.join(tmp.path, 'codex'))..createSync();
      final config = File(p.join(home.path, 'config.toml'))
        ..writeAsStringSync('model_provider = "evil"\n');
      prepareCodexHome(home);
      expect(config.readAsStringSync(), codexConfigToml);
      expect(home.listSync().map((e) => p.basename(e.path)), [
        'config.toml',
      ], reason: 'no temp file left behind');
      // Idempotent: a second run changes nothing.
      final before = config.statSync().modified;
      prepareCodexHome(home);
      expect(config.statSync().modified, before);
    });

    test('the config says what ADR 0013 requires', () {
      expect(
        codexConfigToml,
        contains('cli_auth_credentials_store = "keyring"'),
      );
      expect(codexConfigToml, contains('forced_login_method = "chatgpt"'));
      expect(codexConfigToml, contains('web_search = "disabled"'));
      expect(codexConfigToml, contains('[mcp_servers]'));
      expect(codexConfigToml, contains('check_for_update_on_startup = false'));
      expect(codexConfigToml, isNot(contains('api')));
      expect(codexThreadConfig['web_search'], 'disabled');
      expect(codexThreadConfig['mcp_servers'], isEmpty);
    });

    test('a symlink in the home\'s place, or as config.toml, is refused', () {
      final real = Directory(p.join(tmp.path, 'elsewhere'))..createSync();
      final link = Link(p.join(tmp.path, 'codex'))..createSync(real.path);
      expect(
        () => prepareCodexHome(Directory(link.path)),
        throwsA(isA<FileSystemException>()),
      );
      final home = Directory(p.join(tmp.path, 'home'))..createSync();
      final target = File(p.join(tmp.path, 'target.toml'))
        ..writeAsStringSync('x');
      Link(p.join(home.path, 'config.toml')).createSync(target.path);
      expect(() => prepareCodexHome(home), throwsA(isA<FileSystemException>()));
      expect(
        target.readAsStringSync(),
        'x',
        reason: 'nothing followed the link',
      );
    });

    test('the keychains directory is the user\'s', () {
      expect(
        resolveKeychainsDir({'HOME': '/Users/x'})!.path,
        '/Users/x/Library/Keychains',
      );
      expect(resolveKeychainsDir({}), isNull);
    });
  });
}
