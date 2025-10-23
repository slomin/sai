import 'package:sai/src/lm_client.dart';
import 'package:test/test.dart';

void main() {
  group('SaiModelResponse.fromContent', () {
    test('parses structured json', () {
      final response = SaiModelResponse.fromContent(
        '{"explanation":"Use ls","recommended_command":"ls -a"}',
      );
      expect(response.hasStructured, isTrue);
      expect(response.explanation, 'Use ls');
      expect(response.recommendedCommand, 'ls -a');
    });

    test('parses fenced json', () {
      final response = SaiModelResponse.fromContent('''```json
{
  "explanation": "Check branch",
  "recommended_command": "git branch"
}
```''');
      expect(response.hasStructured, isTrue);
      expect(response.explanation, 'Check branch');
      expect(response.recommendedCommand, 'git branch');
    });

    test('falls back to raw text', () {
      final response = SaiModelResponse.fromContent('Just run ls -la');
      expect(response.hasStructured, isFalse);
      expect(response.displayText, 'Just run ls -la');
    });
  });
}
