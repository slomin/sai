/// Strict JSON decode helpers shared by the task model and the task event
/// payload codecs. Not exported from the package: the public surface is the
/// typed model and events, never these.
library;

import '../archive/blobref.dart';
import '../archive/event.dart' show parseTs;
import 'date.dart';

bool listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

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

String? optionalString(
  Map<String, Object?> map,
  String key, {
  required String where,
  bool emptyOk = false,
}) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String || (!emptyOk && value.isEmpty)) {
    throw FormatException(
      '$where.$key must be a ${emptyOk ? '' : 'non-empty '}string',
    );
  }
  return value;
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
  if (value is! String) {
    throw FormatException('$where.$key must be a blobref string');
  }
  try {
    return BlobRef.parse(value);
  } on FormatException {
    throw FormatException('$where.$key is not a blobref: "$value"');
  }
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
