/// A decision made on the assistant's behalf (#14): what was decided, the
/// alternatives considered, the reasoning and who decided, in the
/// person's own words, with the day it was taken. The value behind the
/// `decision.made` payload — read back leniently, taken in strictly.
library;

import 'dart:convert';

import '../archive/blobref.dart';
import '../json_codec.dart';
import '../tasks/date.dart';

/// The most a decision's encoded payload may be. Prose, not a document —
/// and far under the log's 1 MiB line cap, so the refusal is this
/// family's own words rather than the archive's.
const maxDecisionBytes = 64 * 1024;

final class Decision {
  Decision({
    required this.title,
    required this.decided,
    required this.by,
    required this.decision,
    List<String> alternatives = const [],
    required this.reasoning,
    this.profile,
  }) : alternatives = List.unmodifiable(alternatives);

  /// One line: what the decision is about.
  final String title;

  /// The day the decision was taken — the event's `ts` says when it was
  /// recorded, which for a decision older than the log is later.
  final CalendarDate decided;

  /// Who decided, in their own words.
  final String by;

  /// What was decided. Paragraphs are separated by blank lines.
  final String decision;

  /// What else was considered; may be empty.
  final List<String> alternatives;

  /// Why.
  final String reasoning;

  /// The `profile/system-prompt.md` this decision created or revised, as
  /// the sha256 blobref of the file's exact bytes — so every
  /// `provider.request` can be matched to the text in force.
  final BlobRef? profile;

  static const _keys = {
    'title',
    'decided',
    'by',
    'decision',
    'alternatives',
    'reasoning',
    'profile',
  };

  /// A decision as a person wrote it — the `--from` file, or the answers
  /// to the prompts, as one object. Strict: an unknown key is a typo,
  /// `decided` may be omitted (it is [today]) but never lie in the
  /// future, and the whole must fit [maxDecisionBytes]. Throws
  /// [FormatException] with the reason in fixed words.
  factory Decision.fromInput(
    Map<String, Object?> input, {
    required CalendarDate today,
  }) {
    const where = 'decision';
    rejectUnknownKeys(input, _keys, where: where);
    final decidedText = optionalString(
      input,
      'decided',
      where: where,
      emptyOk: true,
    );
    final CalendarDate decided;
    if (decidedText == null || decidedText.trim().isEmpty) {
      decided = today;
    } else {
      decided = _date(decidedText.trim(), where: where);
      if (decided > today) {
        throw FormatException('$where.decided is after today ($today)');
      }
    }
    final decision = Decision._read(input, decided: decided, where: where);
    final bytes = utf8.encode(jsonEncode(decision.toPayload())).length;
    if (bytes > maxDecisionBytes) {
      throw FormatException(
        'the decision is too long: $bytes bytes, the limit is '
        '$maxDecisionBytes',
      );
    }
    return decision;
  }

  /// A decision as the log holds it. Every field this version knows is
  /// required in its shape; a key a later writer added is ignored, so a
  /// document renders from a log written after this reader's time.
  /// Throws [FormatException] on a line this reader cannot use.
  factory Decision.fromPayload(Map<String, Object?> payload) {
    const where = 'decision';
    final decided = _date(
      requireString(payload, 'decided', where: where),
      where: where,
    );
    return Decision._read(payload, decided: decided, where: where);
  }

  factory Decision._read(
    Map<String, Object?> map, {
    required CalendarDate decided,
    required String where,
  }) {
    final title = _text(map, 'title', where: where);
    if (title.contains('\n')) {
      throw FormatException('$where.title must be one line');
    }
    return Decision(
      title: title,
      decided: decided,
      by: _text(map, 'by', where: where),
      decision: _text(map, 'decision', where: where),
      alternatives: _alternatives(map['alternatives'], where: where),
      reasoning: _text(map, 'reasoning', where: where),
      profile: _profile(map['profile'], where: where),
    );
  }

  static String _text(
    Map<String, Object?> map,
    String key, {
    required String where,
  }) {
    final value = map[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$where.$key must be a non-empty string');
    }
    return value.trim();
  }

  static CalendarDate _date(String text, {required String where}) {
    try {
      return CalendarDate.parse(text);
    } on FormatException {
      throw FormatException(
        '$where.decided is not a calendar date (YYYY-MM-DD): "$text"',
      );
    }
  }

  static List<String> _alternatives(Object? value, {required String where}) {
    if (value == null) return const [];
    if (value is! List) {
      throw FormatException(
        '$where.alternatives must be a list of non-empty strings',
      );
    }
    final out = <String>[];
    for (final item in value) {
      if (item is! String || item.trim().isEmpty) {
        throw FormatException(
          '$where.alternatives must be a list of non-empty strings',
        );
      }
      out.add(item.trim());
    }
    return out;
  }

  static BlobRef? _profile(Object? value, {required String where}) {
    if (value == null) return null;
    final message = '$where.profile must be {"id": <sha256 blobref>}';
    if (value is! Map<String, Object?>) throw FormatException(message);
    final id = value['id'];
    if (id is! String) throw FormatException(message);
    final ref = BlobRef.tryParse(id);
    if (ref == null || !ref.isSha256) throw FormatException(message);
    return ref;
  }

  /// The `decision.made` payload: every field, `profile` only when set.
  Map<String, Object?> toPayload() => {
    'title': title,
    'decided': decided.toString(),
    'by': by,
    'decision': decision,
    'alternatives': alternatives,
    'reasoning': reasoning,
    if (profile != null) 'profile': {'id': profile.toString()},
  };

  @override
  bool operator ==(Object other) {
    if (other is! Decision) return false;
    if (alternatives.length != other.alternatives.length) return false;
    for (var i = 0; i < alternatives.length; i++) {
      if (alternatives[i] != other.alternatives[i]) return false;
    }
    return title == other.title &&
        decided == other.decided &&
        by == other.by &&
        decision == other.decision &&
        reasoning == other.reasoning &&
        profile == other.profile;
  }

  @override
  int get hashCode => Object.hash(
    title,
    decided,
    by,
    decision,
    Object.hashAll(alternatives),
    reasoning,
    profile,
  );

  @override
  String toString() => 'Decision($decided, $title)';
}
