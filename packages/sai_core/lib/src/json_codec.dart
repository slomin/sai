/// Package-internal strict JSON decode helpers shared across archive and
/// task codecs. Public decoders translate malformed input to
/// [FormatException], never VM cast errors.
library;

import 'archive/blobref.dart';

Map<String, Object?> requireObject(Object? value, String where) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$where must be a JSON object');
  }
  return value;
}

void rejectUnknownKeys(
  Map<String, Object?> map,
  Set<String> allowed, {
  required String where,
}) {
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('unknown key in $where: "$key"');
    }
  }
}

String requireString(
  Map<String, Object?> map,
  String key, {
  required String where,
}) {
  final value = map[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$where.$key must be a non-empty string');
  }
  return value;
}

/// Returns null only when [key] is absent. A present null is malformed just
/// like any other non-string value.
String? optionalString(
  Map<String, Object?> map,
  String key, {
  required String where,
  bool emptyOk = false,
}) {
  if (!map.containsKey(key)) return null;
  final value = map[key];
  if (value is! String || (!emptyOk && value.isEmpty)) {
    throw FormatException(
      '$where.$key must be a ${emptyOk ? '' : 'non-empty '}string',
    );
  }
  return value;
}

BlobRef requireBlobRef(Object? value, {required String where}) {
  if (value is! String) {
    throw FormatException('$where must be a blobref string');
  }
  try {
    return BlobRef.parse(value);
  } on FormatException {
    throw FormatException('$where is not a blobref: "$value"');
  }
}

BlobRef? nullableBlobRef(Object? value, {required String where}) =>
    value == null ? null : requireBlobRef(value, where: where);
