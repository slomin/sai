/// Parsing and validating a proposal call's output (#35). Output that
/// fails here is a failed proposal turn: no partial display, no repair
/// pass — the caller records `proposal.refused` and shows nothing.
library;

import 'dart:convert';

import '../tasks/date.dart';
import '../tasks/model.dart';
import '../tasks/projection.dart';
import 'proposal.dart';

/// The fixed reason a proposal was refused; never an exception's text.
final class ProposalFormatError implements Exception {
  const ProposalFormatError(this.reason);

  final String reason;

  @override
  String toString() => 'the proposal could not be read: $reason';
}

/// Validates [text] against the turn that produced it: [handles] is the
/// handle map exactly as the catalog rendered it for this request — a
/// handle from any other turn cannot resolve — and [projection] is the
/// projection those handles were rendered from. `today`/`tomorrow`
/// resolve against [today] to concrete dates, so what is recorded and
/// applied is what was proposed, whenever it is accepted.
ParsedProposal parseProposalText(
  String text, {
  required List<TaskId> handles,
  required TaskProjection projection,
  required CalendarDate today,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw const ProposalFormatError('not JSON');
  }
  if (decoded is! Map<String, Object?>) {
    throw const ProposalFormatError('not an object');
  }
  for (final key in decoded.keys) {
    if (key != 'suggestions' && key != 'note') {
      throw ProposalFormatError("unknown key '$key'");
    }
  }
  final note = decoded['note'];
  if (note is! String) throw const ProposalFormatError("missing 'note'");
  final raw = decoded['suggestions'];
  if (raw is! List) throw const ProposalFormatError("missing 'suggestions'");
  if (raw.length > 8) throw const ProposalFormatError('too many suggestions');

  final items = <Suggestion>[];
  final seen = <(SuggestionKind, TaskId)>{};
  for (final (index, entry) in raw.indexed) {
    if (entry is! Map<String, Object?>) {
      throw const ProposalFormatError('a suggestion is not an object');
    }
    for (final key in entry.keys) {
      if (!const {
        'kind',
        'task',
        'when',
        'deadline',
        'parts',
        'reason',
      }.contains(key)) {
        throw ProposalFormatError("unknown key '$key'");
      }
    }
    final kind = switch (entry['kind']) {
      'schedule' => SuggestionKind.schedule,
      'deadline' => SuggestionKind.deadline,
      'split' => SuggestionKind.split,
      final other => throw ProposalFormatError("bad kind '$other'"),
    };
    final handle = entry['task'];
    if (handle is! String || !_handleForm.hasMatch(handle)) {
      throw ProposalFormatError("bad handle '${entry['task']}'");
    }
    // tryParse: the schema admits any digit run, and a number too big
    // for an int must read as unknown, never as a thrown FormatException.
    final number = int.tryParse(handle.substring(1));
    if (number == null || number < 1 || number > handles.length) {
      throw ProposalFormatError("unknown handle '$handle'");
    }
    final target = handles[number - 1];
    final task = projection.task(target);
    if (task == null ||
        task.deletedAt != null ||
        task.status != TaskStatus.open) {
      throw ProposalFormatError("'$handle' is not an open task");
    }
    if (!seen.add((kind, target))) {
      throw ProposalFormatError("duplicate suggestion for '$handle'");
    }
    final reason = entry['reason'];
    if (reason is! String) {
      throw const ProposalFormatError("missing 'reason'");
    }

    TaskWhen? when;
    CalendarDate? deadline;
    var parts = const <String>[];
    switch (kind) {
      case SuggestionKind.schedule:
        when = switch (_word(entry['when'], 'when')) {
          'today' => TaskWhen.date(today),
          'tomorrow' => TaskWhen.date(today.addDays(1)),
          'someday' => TaskWhen.someday,
          'anytime' => TaskWhen.none,
          final word => TaskWhen.date(
            CalendarDate.tryParse(word) ??
                (throw ProposalFormatError("bad when '$word'")),
          ),
        };
      case SuggestionKind.deadline:
        deadline = switch (_word(entry['deadline'], 'deadline')) {
          'today' => today,
          'tomorrow' => today.addDays(1),
          'none' => null,
          final word =>
            CalendarDate.tryParse(word) ??
                (throw ProposalFormatError("bad deadline '$word'")),
        };
      case SuggestionKind.split:
        final rawParts = entry['parts'];
        if (rawParts is! List) {
          throw const ProposalFormatError('a split needs its parts');
        }
        parts = [
          for (final part in rawParts)
            if (part is String) part.trim() else '',
        ];
        if (parts.length < 2) {
          throw const ProposalFormatError('a split needs at least two parts');
        }
        if (parts.any((part) => part.isEmpty)) {
          throw const ProposalFormatError('a split part is blank');
        }
        if (parts.toSet().length != parts.length) {
          throw const ProposalFormatError('a split part repeats');
        }
    }

    items.add(
      Suggestion(
        index: index,
        kind: kind,
        target: target,
        targetTitle: task.title,
        fingerprint: task.modifiedAt,
        when: when,
        deadline: deadline,
        parts: parts,
        reason: reason,
      ),
    );
  }
  return ParsedProposal(note: note, items: items);
}

/// A non-empty word field, or a refusal naming the field.
String _word(Object? value, String field) {
  if (value is! String || value.isEmpty) {
    throw ProposalFormatError("bad $field '$value'");
  }
  return value;
}

final _handleForm = RegExp(r'^t[0-9]+$');
