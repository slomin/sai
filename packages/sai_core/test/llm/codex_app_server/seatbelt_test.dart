import 'package:sai_core/src/llm/codex_app_server/seatbelt.dart';
import 'package:test/test.dart';

void main() {
  test('the profile is closed by default and opens only the named roots', () {
    expect(seatbeltProfile, startsWith('(version 1)\n(deny default)'));
    // The one program it may start is itself.
    expect(
      RegExp(r'\(allow process-exec[^)]*\)').allMatches(seatbeltProfile).length,
      1,
    );
    expect(
      seatbeltProfile,
      contains('(allow process-exec (literal (param "SIDECAR")))'),
    );
    for (final param in [
      'SIDECAR',
      'CODEX_HOME',
      'SCRATCH',
      'TMP',
      'KEYCHAINS',
    ]) {
      expect(seatbeltProfile, contains('(param "$param")'), reason: param);
    }
    // Nothing of the person's home beyond those parameters.
    expect(seatbeltProfile, isNot(contains('(subpath "/Users')));
    expect(seatbeltProfile, isNot(contains('(param "HOME")')));
    expect(seatbeltProfile, isNot(contains('/bin/sh')));
    expect(seatbeltProfile, isNot(contains('/bin/zsh')));
    // Keychain and trust services the credential lives behind, and the
    // network in and out for login and inference.
    for (final service in [
      'com.apple.SecurityServer',
      'com.apple.securityd',
      'com.apple.trustd.agent',
      'com.apple.networkd',
      'com.apple.ocspd',
    ]) {
      expect(
        seatbeltProfile,
        contains('(global-name "$service")'),
        reason: service,
      );
    }
    expect(seatbeltProfile, contains('(allow network-outbound)'));
    expect(
      seatbeltProfile,
      contains('(allow network-inbound (local ip "localhost:*"))'),
    );
    // Every write is under a parameter, or to /dev.
    for (final line in seatbeltProfile.split('\n')) {
      if (!line.contains('file-write')) continue;
      final clause = seatbeltProfile.substring(seatbeltProfile.indexOf(line));
      final end = clause.indexOf('\n\n');
      final block = end < 0 ? clause : clause.substring(0, end);
      expect(
        block,
        anyOf(contains('(param '), contains('/dev/')),
        reason: line,
      );
    }
  });

  test('the argv passes the profile inline with the roots as parameters', () {
    final args = seatbeltArguments(
      sidecar: '/Applications/sai.app/Contents/Helpers/codex-app-server',
      codexHome: '/Users/x/Library/Application Support/sai/codex',
      scratch: '/Users/x/Library/Application Support/sai/codex-tmp/scratch',
      tmp: '/Users/x/Library/Application Support/sai/codex-tmp',
      keychains: '/Users/x/Library/Keychains',
      sidecarArguments: const ['app-server'],
    );
    expect(sandboxExec, '/usr/bin/sandbox-exec');
    expect(args.take(2), ['-p', seatbeltProfile]);
    expect(
      args,
      containsAllInOrder([
        '-D',
        'SIDECAR=/Applications/sai.app/Contents/Helpers/codex-app-server',
        '-D',
        'CODEX_HOME=/Users/x/Library/Application Support/sai/codex',
        '-D',
        'SCRATCH=/Users/x/Library/Application Support/sai/codex-tmp/scratch',
        '-D',
        'TMP=/Users/x/Library/Application Support/sai/codex-tmp',
        '-D',
        'KEYCHAINS=/Users/x/Library/Keychains',
        '/Applications/sai.app/Contents/Helpers/codex-app-server',
        'app-server',
      ]),
    );
    expect(args.last, 'app-server');
    expect(args, isNot(contains('-f')), reason: 'no profile file to swap');
  });
}
