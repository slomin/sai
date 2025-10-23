import 'package:sai/src/init/generator.dart';
import 'package:test/test.dart';

void main() {
  group('generateShellInitSnippet', () {
    test('returns zsh snippet', () {
      final snippet = generateShellInitSnippet(shell: 'zsh');
      expect(snippet, contains("local _sai_shell='zsh'"));
      expect(snippet, contains('command sai --shell "\$_sai_shell"'));
      expect(snippet, contains('fc -ln -10'));
    });

    test('returns bash snippet', () {
      final snippet = generateShellInitSnippet(shell: 'bash');
      expect(snippet, contains("local _sai_shell='bash'"));
    });

    test('throws for unsupported shell', () {
      expect(
        () => generateShellInitSnippet(shell: 'fish'),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('Unsupported shell'),
          ),
        ),
      );
    });
  });
}
