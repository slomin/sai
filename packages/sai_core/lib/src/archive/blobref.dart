import 'package:crypto/crypto.dart' show sha256;

/// A content address in Perkeep blobref form: `<algorithm>-<lowercase hex>`,
/// e.g. `sha256-b94d27b9…`. The algorithm is part of the reference, so the
/// hash function can change over time without rewriting stored references.
///
/// A blobref names an exact sequence of bytes — for the event log, the bytes
/// of one line as written, excluding the terminating newline. There is no
/// canonicalization: the id of an event is reproducible in any language with
/// `shasum -a 256` alone.
final class BlobRef {
  const BlobRef._(this.algorithm, this.hex);

  /// Computes the sha256 blobref of [bytes] — the exact bytes, as written.
  factory BlobRef.sha256OfBytes(List<int> bytes) =>
      BlobRef._(_sha256, sha256.convert(bytes).toString());

  /// Parses [text] as a blobref.
  ///
  /// Unknown algorithm names are accepted (a future reader must be able to
  /// hold references written after its time), but the known ones are held to
  /// their digest length. Throws [FormatException] on malformed input.
  factory BlobRef.parse(String text) {
    final match = _form.firstMatch(text);
    if (match == null) {
      throw FormatException('not a blobref: "$text"');
    }
    final algorithm = match[1]!;
    final hex = match[2]!;
    if (algorithm == _sha256 && hex.length != 64) {
      throw FormatException(
        'sha256 blobref carries ${hex.length} hex characters, expected 64',
        text,
      );
    }
    return BlobRef._(algorithm, hex);
  }

  /// Like [BlobRef.parse], but returns null instead of throwing.
  static BlobRef? tryParse(String text) {
    try {
      return BlobRef.parse(text);
    } on FormatException {
      return null;
    }
  }

  static const _sha256 = 'sha256';
  static final _form = RegExp(r'^([a-z][a-z0-9]*)-([a-f0-9]+)$');

  /// Lowercase hash algorithm name, e.g. `sha256`.
  final String algorithm;

  /// Lowercase hex digest.
  final String hex;

  /// Whether this ref uses the algorithm the log currently writes.
  bool get isSha256 => algorithm == _sha256;

  @override
  String toString() => '$algorithm-$hex';

  @override
  bool operator ==(Object other) =>
      other is BlobRef && other.algorithm == algorithm && other.hex == hex;

  @override
  int get hashCode => Object.hash(algorithm, hex);
}
