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

  group('the release tooling (#95)', () {
    late Map<String, String> scripts;
    setUpAll(() {
      scripts = {
        for (final f in Directory(
          '${repo.path}/tool',
        ).listSync(recursive: true))
          if (f is File && f.path.endsWith('.sh')) rel(f): f.readAsStringSync(),
      };
    });

    /// Code lines only: a comment may name a command it forbids.
    Iterable<String> code(String text) => text
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'^\s*#.*'), ''))
        .where((l) => l.trim().isNotEmpty);

    test('the only security call enumerates the dedicated keychain', () {
      final calls = <String, List<String>>{};
      for (final MapEntry(key: path, value: text) in scripts.entries) {
        final lines = code(text)
            .where((l) => RegExp(r'(^|[\s(;|&])security\s').hasMatch(l))
            .toList();
        if (lines.isNotEmpty) calls[path] = lines;
      }
      expect(calls.keys, ['tool/release.sh']);
      expect(calls['tool/release.sh'], hasLength(1));
      expect(
        calls['tool/release.sh']!.single.trim(),
        matches(
          RegExp(
            r'^found=\$\(security find-identity -v -p codesigning '
            r'"\$signing_keychain" 2>/dev/null\)',
          ),
        ),
      );
    });

    test('no script touches generic passwords or mutates a keychain', () {
      final forbidden = RegExp(
        r'find-generic-password|find-internet-password|dump-keychain|'
        r'unlock-keychain|lock-keychain|set-key-partition-list|'
        r'list-keychains|add-generic-password|delete-generic-password|'
        r'delete-keychain|create-keychain|security import|set-keychain',
      );
      for (final MapEntry(key: path, value: text) in scripts.entries) {
        expect(code(text).where(forbidden.hasMatch), isEmpty, reason: path);
      }
    });

    test('no user-supplied identity selector remains', () {
      final files =
          [
                ...Directory('${repo.path}/tool').listSync(recursive: true),
                ...Directory('${repo.path}/docs').listSync(recursive: true),
                File('${repo.path}/README.md'),
                File('${repo.path}/AGENTS.md'),
                ...Directory('${repo.path}/apps/sai_app/macos')
                    .listSync(recursive: true),
              ]
              .whereType<File>()
              .where((f) => !f.path.contains('/build/'))
              .where(
                (f) => RegExp(
                  r'\.(sh|md|yml|yaml|xcconfig|plist|swift|py|dart|txt|entitlements)$',
                ).hasMatch(f.path),
              );
      for (final f in files) {
        expect(
          f.readAsStringSync(),
          isNot(contains('SAI_CODESIGN_IDENTITY')),
          reason: rel(f),
        );
      }
    });

    test('nothing builds or resolves after stable authorization', () {
      final release = scripts['tool/release.sh']!;
      String body(String name) {
        final match = RegExp(
          '^$name\\(\\) \\{\\n(.*?)^\\}',
          multiLine: true,
          dotAll: true,
        ).firstMatch(release);
        expect(match, isNotNull, reason: '$name() in release.sh');
        return match!.group(1)!;
      }

      final toolchain = RegExp(
        r'(^|[\s(;|&])(dart|flutter|pub|xcodebuild|cc|clang|swift|make|'
        r'gh|git|tool/build-tui\.sh|\$\(.*hook)\b',
      );
      for (final name in [
        'stable_identity',
        'sign',
        'sign_tree',
        'package_release',
        'replace_release',
      ]) {
        expect(
          code(body(name)).where(toolchain.hasMatch),
          isEmpty,
          reason: '$name() runs only codesign and the packaging tools',
        );
      }
      // Signing is never --deep; verification of the app is.
      expect(
        code(release)
            .where((l) => l.contains('--sign') && l.contains('--deep')),
        isEmpty,
      );
      expect(release, contains('codesign --verify --deep --strict'));
    });
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
