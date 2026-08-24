/// Strict JSON decode helpers shared by the task model and the task event
/// payload codecs. Not exported from the package: the public surface is the
/// typed model and events, never these.
library;

import '../archive/blobref.dart';
import '../archive/event.dart' show parseTs;
import '../json_codec.dart';
import 'date.dart';

export '../json_codec.dart';

bool listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

BlobRef requireId(
  Map<String, Object?> map,
  String key, {
  required String where,
}) {
  final id = optionalId(map, key, where: where);
  if (id == null) {
    throw FormatException('$where.$key must be a blobref');
  }
  return id;
}

BlobRef? optionalId(
  Map<String, Object?> map,
  String key, {
  required String where,
}) {
  final value = map[key];
  if (value == null) return null;
  return requireBlobRef(value, where: '$where.$key');
}

DateTime requireInstant(
  Map<String, Object?> map,
  String key, {
  required String where,
}) {
  final instant = optionalInstant(map, key, where: where);
  if (instant == null) {
    throw FormatException('$where.$key must be a timestamp');
  }
  return instant;
}

DateTime? optionalInstant(
  Map<String, Object?> map,
  String key, {
  required String where,
}) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('$where.$key must be a timestamp string');
  }
  try {
    return parseTs(value);
  } on FormatException catch (e) {
    throw FormatException('$where.$key: ${e.message}');
  }
}

CalendarDate? optionalDate(
  Map<String, Object?> map,
  String key, {
  required String where,
}) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('$where.$key must be a date string');
  }
  try {
    return CalendarDate.parse(value);
  } on FormatException catch (e) {
    throw FormatException('$where.$key: ${e.message}');
  }
}

List<Object?> jsonList(
  Map<String, Object?> map,
  String key, {
  required String where,
}) {
  final value = map[key];
  if (value == null) return const [];
  if (value is! List) {
    throw FormatException('$where.$key must be a list');
  }
  return value;
}

List<BlobRef> idList(
  Map<String, Object?> map,
  String key, {
  required String where,
}) => [
  for (final entry in jsonList(map, key, where: where))
    () {
      if (entry is! String) {
        throw FormatException('$where.$key entries must be blobref strings');
      }
      try {
        return BlobRef.parse(entry);
      } on FormatException {
        throw FormatException('$where.$key entry is not a blobref: "$entry"');
      }
    }(),
];
