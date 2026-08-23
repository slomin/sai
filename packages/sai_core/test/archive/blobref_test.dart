import 'dart:convert';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  group('BlobRef.sha256OfBytes', () {
    test('hashes the empty input to the well-known digest', () {
      final ref = BlobRef.sha256OfBytes(const []);
      expect(
        ref.toString(),
        'sha256-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('matches an externally computed digest (shasum -a 256)', () {
      // printf 'hello world' | shasum -a 256
      final ref = BlobRef.sha256OfBytes(utf8.encode('hello world'));
      expect(
        ref.hex,
        'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
      );
      expect(ref.algorithm, 'sha256');
    });

    test('hashes exact bytes: JSON text digest matches shasum', () {
      // printf '{"a":1}' | shasum -a 256
      final ref = BlobRef.sha256OfBytes(utf8.encode('{"a":1}'));
      expect(
        ref.hex,
        '015abd7f5cc57a2dd94b7590f04ad8084273905ee33ec5cebeae62276a97f862',
      );
    });
  });

  group('BlobRef.parse', () {
    test('round-trips its own toString', () {
      final ref = BlobRef.sha256OfBytes(utf8.encode('x'));
      expect(BlobRef.parse(ref.toString()), ref);
    });

    test('tolerates unknown future algorithms', () {
      final ref = BlobRef.parse('blake3-00ff');
      expect(ref.algorithm, 'blake3');
      expect(ref.hex, '00ff');
      expect(ref.isSha256, isFalse);
    });

    test('rejects malformed refs', () {
      for (final bad in [
        '',
        'sha256',
        'sha256-',
        '-abcdef',
        'sha256-ABCDEF', // uppercase hex
        'SHA256-abcdef', // uppercase algorithm
        'sha256-abcdeg', // non-hex
        'sha256:abcdef', // wrong separator
        ' sha256-abcdef',
        'sha256-abcdef\n',
      ]) {
        expect(
          () => BlobRef.parse(bad),
          throwsFormatException,
          reason: 'should reject: "$bad"',
        );
        expect(BlobRef.tryParse(bad), isNull, reason: 'tryParse: "$bad"');
      }
    });

    test('a sha256 ref must carry a 64-character digest', () {
      expect(() => BlobRef.parse('sha256-abcdef'), throwsFormatException);
      final ok = 'sha256-${'0' * 64}';
      expect(BlobRef.parse(ok).toString(), ok);
    });
  });

  test('equality and hashCode follow the textual form', () {
    final a = BlobRef.sha256OfBytes(utf8.encode('same'));
    final b = BlobRef.sha256OfBytes(utf8.encode('same'));
    final c = BlobRef.sha256OfBytes(utf8.encode('other'));
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a == c, isFalse);
  });
}
