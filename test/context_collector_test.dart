import 'package:sai/src/context/config.dart';
import 'package:sai/src/context/context_collector.dart';
import 'package:test/test.dart';

void main() {
  test('collect applies redaction and history limit', () async {
    final collector = SaiContextCollector(
      config: SaiContextConfig(
        environment: {
          'SAI_HISTORY_COUNT': '2',
        },
      ),
    );

    final payload = await collector.collect(
      message: 'password=abc',
      shell: 'zsh',
      historyLines: const ['git status', 'token=123', 'npm run dev'],
      historyProvided: true,
    );

    expect(payload.message, contains('REDACTED'));
    expect(payload.history.length, 2);
    expect(payload.history.first, contains('REDACTED'));
  });

  test('collect respects SAI_NO_SEND flags', () async {
    final collector = SaiContextCollector(
      config: SaiContextConfig(
        environment: {
          'SAI_NO_SEND': 'history,pwd',
        },
      ),
    );

    final payload = await collector.collect(
      message: 'hello',
      shell: 'zsh',
      historyLines: const ['ls'],
      historyProvided: true,
    );

    expect(payload.history, isEmpty);
    expect(payload.cwd, isEmpty);
  });

  test('historyFilePath exposes environment value', () {
    final collector = SaiContextCollector(
      config: SaiContextConfig(
        environment: {
          'SAI_HISTORY_FILE': '/tmp/history',
        },
      ),
    );

    expect(collector.historyFilePath, '/tmp/history');
  });
}
