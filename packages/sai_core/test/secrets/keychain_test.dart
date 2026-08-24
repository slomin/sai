@TestOn('mac-os')
library;

import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

/// Every test runs against a throwaway keychain file under a temp
/// directory, created by this process with a known password: nothing here
/// touches the login keychain, and nothing prompts.
void main() {
  late Directory tmp;
  late KeychainSecretStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sai_keychain_test');
    store = KeychainSecretStore.file(
      '${tmp.path}/test.keychain-db',
      password: 'test-only',
      service: 'me.slominski.sai.test',
    );
  });

  tearDown(() {
    store.destroy();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('a missing item reads as null and is not present', () {
    expect(store.read('provider:x'), isNull);
    expect(store.has('provider:x'), isFalse);
    expect(store.delete('provider:x'), isFalse);
  });

  test('write, read, update in place, delete', () {
    store.write('provider:x', 'first');
    expect(store.read('provider:x'), 'first');
    expect(store.has('provider:x'), isTrue);
    store.write('provider:x', 'second');
    expect(store.read('provider:x'), 'second');
    expect(store.delete('provider:x'), isTrue);
    expect(store.read('provider:x'), isNull);
  });

  test('accounts do not bleed into each other', () {
    store.write('provider:a', 'A');
    store.write('provider:b', 'B');
    expect(store.read('provider:a'), 'A');
    expect(store.read('provider:b'), 'B');
    store.delete('provider:a');
    expect(store.read('provider:a'), isNull);
    expect(store.read('provider:b'), 'B');
  });

  test('non-ASCII values round-trip as UTF-8', () {
    store.write('provider:u', 'pässwörd ✓ 🔑');
    expect(store.read('provider:u'), 'pässwörd ✓ 🔑');
  });

  test('an empty value and a malformed account are refused', () {
    expect(() => store.write('provider:x', ''), throwsArgumentError);
    expect(() => store.write('no spaces', 'v'), throwsArgumentError);
    expect(store.has('provider:x'), isFalse);
  });

  test(
    'the keychain file is where it was asked for, and destroy removes it',
    () {
      final file = File('${tmp.path}/test.keychain-db');
      expect(file.existsSync(), isTrue);
      store.write('provider:x', 'v');
      store.destroy();
      expect(file.existsSync(), isFalse);
      // Never a silent fall-through to the login keychain.
      expect(() => store.read('provider:x'), throwsStateError);
      expect(() => store.write('provider:x', 'v'), throwsStateError);
      expect(() => store.has('provider:x'), throwsStateError);
      expect(() => store.delete('provider:x'), throwsStateError);
    },
  );

  test('a second store over the same file sees the same items', () {
    store.write('provider:x', 'shared');
    final again = KeychainSecretStore.file(
      '${tmp.path}/test.keychain-db',
      password: 'test-only',
      service: 'me.slominski.sai.test',
    );
    expect(again.read('provider:x'), 'shared');
  });
}
