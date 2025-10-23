import 'package:sai/src/context/redaction.dart';
import 'package:test/test.dart';

void main() {
  test('redact replaces secrets with placeholder', () {
    final redactor = SaiRedactor();
    final input = 'password=mySecret token=abc123 ghp_ABCDEFGHIJKLMNOPQRST';
    final result = redactor.redact(input);
    expect(result, isNot(contains('mySecret')));
    expect(result, isNot(contains('abc123')));
    expect(result, isNot(contains('ghp_ABCDEFGHIJKLMNOPQRST')));
    expect(result, contains('REDACTED'));
  });
}
