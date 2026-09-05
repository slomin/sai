/// The decision log as a person reads it (#14): a Markdown view of the
/// `decision.made` lines, rendered beside the archive. Derived, personal
/// and regenerable — never a repository file, and nothing reads it back.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../archive/archive.dart';
import 'decision.dart';
import 'events.dart';

/// Where the rendered log lives: `decisions.md` beside the archive root —
/// in the data directory next to `settings.json` for an installed sai
/// (ADR 0006), beside a scratch root's `archive/` otherwise. In the
/// person's custody, like the log it is a view of.
File decisionLogFile(Directory archiveRoot) =>
    File(p.join(archiveRoot.parent.path, 'decisions.md'));

/// Renders every `decision.made` among [events], in chain order, as one
/// Markdown document. Pure: the same lines give the same text. A line
/// whose payload this version cannot read is one entry saying so — the
/// document never fails as a whole.
String renderDecisionLog(Iterable<StoredEvent> events) {
  final decisions = [
    for (final stored in events)
      if (stored.event.type == DecisionEventTypes.made) stored,
  ];
  final out = StringBuffer()
    ..writeln("# Decisions made on sai's behalf")
    ..writeln()
    ..writeln(
      'Rendered by `sai_tui decision render` from the `decision.made` lines of',
    )
    ..writeln(
      'the archive. A view of the log, not a record of its own: do not edit',
    )
    ..writeln(
      'it — record a decision with `sai_tui decision add` and render again.',
    )
    ..writeln(
      'The format is § Decisions (#14) of docs/archive/event-log-v0.md in the',
    )
    ..writeln('sai repository.')
    ..writeln();
  if (decisions.isEmpty) {
    out.writeln('No decisions recorded yet.');
    return out.toString();
  }
  final newest = _day(decisions.last);
  out.writeln(
    decisions.length == 1
        ? '1 decision, recorded $newest.'
        : '${decisions.length} decisions; the newest was recorded $newest.',
  );
  for (final (index, stored) in decisions.indexed) {
    out.writeln();
    _entry(out, index + 1, stored);
  }
  return out.toString();
}

/// Every `decision.made` line of [archive], oldest first. Lock-free, so a
/// read can overlap an append in flight and see a torn tail; it is read
/// once more, the shape the task store's replay uses.
Future<List<StoredEvent>> readDecisions(Archive archive) async {
  for (var attempt = 0; ; attempt++) {
    try {
      return [
        await for (final stored in archive.events())
          if (stored.event.type == DecisionEventTypes.made) stored,
      ];
    } on TornTailError {
      if (attempt > 0) rethrow;
    }
  }
}

/// The per-process temp file a write goes through. The document sits in
/// the data directory, outside the archive root and its LOCK, so no lock
/// guards it and the name carries the pid — as the settings file's does:
/// two renders at once cannot truncate or rename each other's temp, and
/// the rename is last-write-wins, which a view of the log can afford.
File decisionLogTempFile(File file) => File('${file.path}.$pid.tmp');

/// Writes [text] to [file] whole — [decisionLogTempFile] beside it, then
/// a rename — creating the directory when it is missing. A write that
/// fails takes its own temp file with it (nothing sweeps the data
/// directory) and names the document, never the temp file.
void writeDecisionLog(File file, String text) {
  file.parent.createSync(recursive: true);
  final tmp = decisionLogTempFile(file);
  try {
    tmp.writeAsStringSync(text, flush: true);
    tmp.renameSync(file.path);
  } on FileSystemException catch (e) {
    try {
      tmp.deleteSync();
    } on FileSystemException {
      // Never created, or already gone.
    }
    throw FileSystemException(e.message, file.path, e.osError);
  }
}

String _day(StoredEvent stored) => stored.event.tsText.substring(0, 10);

void _entry(StringBuffer out, int number, StoredEvent stored) {
  final Decision decision;
  try {
    decision = Decision.fromPayload(stored.event.payload);
  } on FormatException catch (e) {
    out
      ..writeln('## $number. An unreadable decision')
      ..writeln()
      ..writeln('Recorded ${_day(stored)} · `${stored.id}` · ${e.message}');
    return;
  }
  out
    ..writeln('## $number. ${decision.title}')
    ..writeln()
    ..writeln(
      'Decided ${decision.decided} by ${decision.by} · '
      'recorded ${_day(stored)} · `${stored.id}`',
    )
    ..writeln()
    ..writeln('**Decision.** ${decision.decision}')
    ..writeln();
  if (decision.alternatives.isEmpty) {
    out.writeln('**Alternatives considered.** None recorded.');
  } else {
    out
      ..writeln('**Alternatives considered.**')
      ..writeln();
    for (final alternative in decision.alternatives) {
      out.writeln('- $alternative');
    }
  }
  out
    ..writeln()
    ..writeln('**Reasoning.** ${decision.reasoning}');
  if (decision.profile != null) {
    out
      ..writeln()
      ..writeln('**Profile.** `${decision.profile}`');
  }
}
