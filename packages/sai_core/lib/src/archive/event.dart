import 'dart:collection';
import 'dart:convert';

import 'blobref.dart';

/// Who an event speaks for. Serialized as the lowercase name.
enum Actor { user, assistant, system }

/// The hard ceiling on one encoded line. Larger content goes out of line
/// (a blob store, v0.2); the cap follows Perkeep's schema-blob limit.
const int maxLineBytes = 1 << 20;

/// Model lineage: which model produced (or is asked to produce) an event.
final class ModelRef {
  const ModelRef({
    required this.provider,
    required this.id,
    this.version,
    this.requestId,
  });

  /// Provider name, e.g. `anthropic`.
  final String provider;

  /// Model id as requested, e.g. `claude-fable-5`.
  final String id;

  /// Exact model version, where the provider exposes one.
  final String? version;

  /// Provider request id, where the provider exposes one.
  final String? requestId;

  Map<String, Object?> _toJson() => {
    'provider': provider,
    'id': id,
    if (version != null) 'version': version,
    if (requestId != null) 'request_id': requestId,
  };

  static ModelRef _fromJson(Object? json) {
    final map = _requireObject(json, 'model');
    _rejectUnknownKeys(map, const {
      'provider',
      'id',
      'version',
      'request_id',
    }, where: 'model');
    return ModelRef(
      provider: _requireString(map, 'provider', where: 'model'),
      id: _requireString(map, 'id', where: 'model'),
      version: _optionalString(map, 'version', where: 'model'),
      requestId: _optionalString(map, 'request_id', where: 'model'),
    );
  }
}

/// What a producer hands to the archive: an event without a place in the
/// chain. `prev` and the final timestamp belong to the log, not the producer.
final class EventDraft {
  EventDraft({
    required this.type,
    required this.actor,
    required this.source,
    required this.payload,
    this.model,
    this.refs,
    this.ts,
  });

  final String type;
  final Actor actor;
  final String source;
  final Map<String, Object?> payload;
  final ModelRef? model;
  final List<BlobRef>? refs;

  /// Optional explicit timestamp; the archive uses its clock when absent.
  final DateTime? ts;
}

/// A fully validated v0 event, ready to be written or already read back.
///
/// An event's id is not a field: it is the sha256 blobref of the encoded
/// line's exact bytes, derived where needed. See `docs/archive/event-log-v0.md`.
final class Event {
  Event._({
    required this.ts,
    required this.tsText,
    required this.type,
    required this.actor,
    required this.source,
    required this.payload,
    required this.model,
    required this.refs,
    required this.prev,
  });

  /// Seals [draft] into the chain position after [prev] at time [ts].
  ///
  /// Throws [ArgumentError] when the draft violates the schema: an
  /// assistant event without a model block, an oversized line, a type
  /// that is not dotted lowercase, or a payload that is not JSON.
  factory Event.seal(EventDraft draft, {required BlobRef? prev, DateTime? ts}) {
    final at = (ts ?? draft.ts ?? DateTime.timestamp()).toUtc();
    final event = Event._(
      ts: at,
      tsText: formatTs(at),
      type: draft.type,
      actor: draft.actor,
      source: draft.source,
      payload: draft.payload,
      model: draft.model,
      refs: List.unmodifiable(draft.refs ?? const <BlobRef>[]),
      prev: prev,
    );
    event._validate(throwing: ArgumentError.new);
    return event;
  }

  /// Decodes and strictly validates one line (without its newline).
  ///
  /// Throws [FormatException] on anything the spec does not allow.
  factory Event.decodeLine(String line) {
    if (utf8.encode(line).length > maxLineBytes) {
      throw const FormatException('line exceeds 1 MiB');
    }
    final Object? json;
    try {
      json = jsonDecode(line);
    } on FormatException catch (e) {
      throw FormatException('not JSON: ${e.message}');
    }
    final map = _requireObject(json, 'event');
    _rejectUnknownKeys(map, const {
      'v',
      'ts',
      'type',
      'actor',
      'source',
      'payload',
      'model',
      'refs',
      'prev',
    }, where: 'event');
    if (map['v'] != 0) {
      throw FormatException('unsupported event version: ${map['v']}');
    }
    final tsText = _requireString(map, 'ts', where: 'event');
    final actorName = _requireString(map, 'actor', where: 'event');
    final actor = Actor.values.asNameMap()[actorName];
    if (actor == null) {
      throw FormatException('unknown actor: "$actorName"');
    }
    if (!map.containsKey('prev')) {
      throw const FormatException('missing key: prev');
    }
    final prevText = map['prev'];
    final event = Event._(
      ts: _parseTs(tsText),
      tsText: tsText,
      type: _requireString(map, 'type', where: 'event'),
      actor: actor,
      source: _requireString(map, 'source', where: 'event'),
      payload: Map<String, Object?>.from(
        _requireObject(map['payload'], 'payload'),
      ),
      model: map.containsKey('model') ? ModelRef._fromJson(map['model']) : null,
      refs: _parseRefs(map['refs'], present: map.containsKey('refs')),
      prev: prevText == null ? null : _parseRef(prevText, where: 'prev'),
    );
    event._validate(throwing: FormatException.new);
    return event;
  }

  /// Event time, UTC. Informational: ordering authority is the chain.
  final DateTime ts;

  /// The timestamp exactly as written on the line.
  final String tsText;

  /// Dotted lowercase type name from the registry in the spec.
  final String type;

  final Actor actor;

  /// The writing client, e.g. `sai/tui`.
  final String source;

  /// Free-form JSON object; its schema is owned by [type].
  final Map<String, Object?> payload;

  /// Required when [actor] is [Actor.assistant]; allowed anywhere.
  final ModelRef? model;

  /// Earlier events this one refers to. Never line numbers.
  final List<BlobRef> refs;

  /// Id of the previous event in the archive, or null for the genesis event.
  final BlobRef? prev;

  static final _typeForm = RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$');

  void _validate({required Object Function(String) throwing}) {
    if (!_typeForm.hasMatch(type)) {
      throw throwing('type must be dotted lowercase, got "$type"');
    }
    if (source.isEmpty) {
      throw throwing('source must not be empty');
    }
    if (actor == Actor.assistant && model == null) {
      throw throwing('an assistant event must carry a model block');
    }
    final String line;
    try {
      line = encode();
    } on JsonUnsupportedObjectError {
      throw throwing('payload is not plain JSON');
    }
    if (utf8.encode(line).length > maxLineBytes) {
      throw throwing('encoded line exceeds 1 MiB');
    }
  }

  /// The line text (no newline): compact JSON, keys sorted recursively.
  ///
  /// Determinism here is a courtesy for diffs and dedup — the format's hash
  /// rule is "the exact bytes as written", whatever those bytes are.
  String encode() => jsonEncode(
    _sortedDeep({
      'v': 0,
      'ts': tsText,
      'type': type,
      'actor': actor.name,
      'source': source,
      'payload': payload,
      if (model != null) 'model': model!._toJson(),
      if (refs.isNotEmpty) 'refs': [for (final r in refs) r.toString()],
      'prev': prev?.toString(),
    }),
  );

  /// The blobref of [encode]'s UTF-8 bytes — this event's id once stored.
  BlobRef deriveId() => BlobRef.sha256OfBytes(utf8.encode(encode()));
}

/// Well-known event types. The registry lives in the spec; producers add to
/// both. A breaking payload change means a new type name, never a rewrite.
abstract final class EventTypes {
  static const chatMessage = 'chat.message';
  static const providerRequest = 'provider.request';
  static const providerResponse = 'provider.response';
  static const toolCall = 'tool.call';
  static const toolResult = 'tool.result';
  static const correction = 'archive.correction';
}

final _tsForm = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$');

/// Formats [time] as the spec's timestamp: RFC 3339 UTC, literal `Z`,
/// exactly six fractional digits — so lexicographic order is chronological.
String formatTs(DateTime time) {
  final utc = time.toUtc();
  String pad(int n, int width) => n.toString().padLeft(width, '0');
  final micros = utc.millisecond * 1000 + utc.microsecond;
  return '${pad(utc.year, 4)}-${pad(utc.month, 2)}-${pad(utc.day, 2)}'
      'T${pad(utc.hour, 2)}:${pad(utc.minute, 2)}:${pad(utc.second, 2)}'
      '.${pad(micros, 6)}Z';
}

DateTime _parseTs(String text) {
  if (!_tsForm.hasMatch(text)) {
    throw FormatException(
      'ts must be RFC 3339 UTC with exactly six fractional digits, got "$text"',
    );
  }
  final parsed = DateTime.parse(text);
  // DateTime.parse accepts overflowing components (2026-13-01); round-trip
  // through the formatter to reject them.
  if (formatTs(parsed) != text) {
    throw FormatException('ts is not a real instant: "$text"');
  }
  return parsed;
}

BlobRef _parseRef(Object? value, {required String where}) {
  if (value is! String) {
    throw FormatException('$where must be a blobref string');
  }
  try {
    return BlobRef.parse(value);
  } on FormatException {
    throw FormatException('$where is not a blobref: "$value"');
  }
}

List<BlobRef> _parseRefs(Object? value, {required bool present}) {
  if (!present) return const [];
  if (value is! List || value.isEmpty) {
    throw const FormatException('refs, when present, must be a non-empty list');
  }
  return List.unmodifiable([
    for (final entry in value) _parseRef(entry, where: 'refs entry'),
  ]);
}

Map<String, Object?> _requireObject(Object? value, String where) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$where must be a JSON object');
  }
  return value;
}

String _requireString(
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

String? _optionalString(
  Map<String, Object?> map,
  String key, {
  required String where,
}) {
  if (!map.containsKey(key)) return null;
  final value = map[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$where.$key must be a non-empty string');
  }
  return value;
}

void _rejectUnknownKeys(
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

Object? _sortedDeep(Object? value) => switch (value) {
  Map<String, Object?>() => SplayTreeMap<String, Object?>.of({
    for (final e in value.entries) e.key: _sortedDeep(e.value),
  }),
  List() => [for (final entry in value) _sortedDeep(entry)],
  _ => value,
};
