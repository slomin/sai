import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  late InMemorySecretStore store;

  setUp(() => store = InMemorySecretStore());

  test('starts empty', () {
    expect(store.read('provider:x'), isNull);
    expect(store.has('provider:x'), isFalse);
    expect(store.delete('provider:x'), isFalse);
    expect(store.accounts, isEmpty);
  });

  test('write, read, replace in place, delete', () {
    store.write('provider:x', 'one');
    expect(store.read('provider:x'), 'one');
    expect(store.has('provider:x'), isTrue);
    store.write('provider:x', 'two');
    expect(store.read('provider:x'), 'two');
    expect(store.accounts, ['provider:x']);
    expect(store.delete('provider:x'), isTrue);
    expect(store.read('provider:x'), isNull);
  });

  test('accounts are independent', () {
    store.write('provider:a', 'A');
    store.write('provider:b', 'B');
    expect(store.read('provider:a'), 'A');
    expect(store.read('provider:b'), 'B');
    store.delete('provider:a');
    expect(store.read('provider:b'), 'B');
  });

  test('an empty value is refused without being quoted', () {
    expect(() => store.write('provider:x', ''), throwsA(isA<ArgumentError>()));
  });

  test('a malformed account is refused, and the value never surfaces', () {
    for (final bad in ['', 'has space', 'tab\there', 'ünïcode']) {
      expect(
        () => store.write(bad, 'sk-canary-value'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            isNot(contains('sk-canary-value')),
          ),
        ),
        reason: '"$bad"',
      );
    }
  });

  test('the exception names the status and never a value', () {
    expect(
      const SecretStoreException('item not found', status: -25300).toString(),
      'SecretStoreException: item not found (-25300)',
    );
    expect(
      const SecretStoreException('unsupported here').toString(),
      'SecretStoreException: unsupported here',
    );
  });
}
