import 'dart:io';

import 'package:test/test.dart';

import 'package_root.dart';

/// Coding agents build this repository with a shell as the same user, so
/// no test may spawn the real `claude` or `codex` binaries against a real
/// home, and provider code spawns them only through the injected process
/// runner (#56, ADR 0013). Everything under `packages/` and `apps/` is
/// scanned; the allowlist names the few places a process may be started.
void main() {
  late Directory repo;

  setUpAll(() async => repo = (await packageRoot()).parent.parent);

  /// Files that may call `Process.*`, relative to the repository root.
  const allowed = {
    // The default runner the provider layer injects (#25, #26).
    'packages/sai_core/lib/src/process/',
    // Runs a second Dart VM with HTTP_PROXY set to prove it is ignored.
    'packages/sai_core/test/llm/openai_compatible/provider_test.dart',
    // Mints a throwaway self-signed certificate with openssl.
    'packages/sai_core/test/llm/stub_server.dart',
    // chmods a settings file unreadable and back.
    'packages/sai_core/test/settings/store_test.dart',
  };

  final spawn = RegExp(r'\bProcess\.(start|run|runSync)\s*\(');
  final vendorBinary = RegExp(
    r'''\bProcess\.(start|run|runSync)\s*\(\s*['"](claude|codex|security)['"]''',
  );

  Iterable<File> dartFiles() => ['packages', 'apps']
      .map((d) => Directory('${repo.path}/$d'))
      .expand((d) => d.listSync(recursive: true))
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .where((f) => !f.path.contains('/.dart_tool/'))
      .where((f) => !f.path.contains('/build/'));

  String rel(File f) => f.path.substring(repo.path.length + 1);

  test('processes are started only from the allowlisted files', () {
    final offenders = dartFiles()
        .where((f) => spawn.hasMatch(f.readAsStringSync()))
        .map(rel)
        .where((p) => !allowed.any(p.startsWith))
        .toList();
    expect(offenders, isEmpty);
  });

  test('nothing spawns claude, codex or security by name', () {
    final offenders = dartFiles()
        .where((f) => vendorBinary.hasMatch(f.readAsStringSync()))
        .map(rel)
        .toList();
    expect(offenders, isEmpty);
  });

  test('every allowlisted file still exists or is a reserved directory', () {
    for (final path in allowed) {
      if (path.endsWith('/')) continue;
      expect(
        File('${repo.path}/$path').existsSync(),
        isTrue,
        reason: '$path left the tree; drop it from the allowlist',
      );
    }
  });
}
