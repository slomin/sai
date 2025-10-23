import 'package:sai/src/lm_client.dart';
import 'package:test/test.dart';

void main() {
  group('SaiLmConfig', () {
    test('uses defaults when env empty', () {
      final config = SaiLmConfig.fromEnvironment({});
      expect(config.enabled, isTrue);
      expect(config.endpoint.toString(),
          'http://localhost:1234/v1/chat/completions');
      expect(config.model, 'qwen3-vl-4b-instruct-mlx');
      expect(config.systemPrompt, contains('command line helper'));
      expect(config.timeout, equals(const Duration(seconds: 15)));
      expect(config.temperature, isNull);
    });

    test('parses overrides and disable flag', () {
      final config = SaiLmConfig.fromEnvironment({
        'SAI_LM_ENDPOINT': 'http://127.0.0.1:9000/v1/chat/completions',
        'SAI_LM_MODEL': 'test-model',
        'SAI_LM_SYSTEM_PROMPT': 'Be helpful',
        'SAI_LM_TEMPERATURE': '0.25',
        'SAI_LM_TIMEOUT_SECONDS': '30',
        'SAI_LM_DISABLED': 'true',
      });

      expect(config.enabled, isFalse);
      expect(config.endpoint.toString(),
          'http://127.0.0.1:9000/v1/chat/completions');
      expect(config.model, 'test-model');
      expect(config.systemPrompt, 'Be helpful');
      expect(config.temperature, closeTo(0.25, 0.0001));
      expect(config.timeout, equals(const Duration(seconds: 30)));
    });
  });
}
