/// The decision log as a person reads it (#14): a Markdown view of the
/// `decision.made` lines, kept in the data directory. Derived, personal
/// and regenerable — never a repository file, and nothing reads it back.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../archive/archive.dart';
import '../archive/archive_root.dart';
import '../identity.dart';
import '../tasks/date.dart';
import 'decision.dart';
import 'events.dart';

/// Where the rendered log lives: `SAI_DECISIONS_FILE` when set, else
/// `decisions.md` in sai's data directory, beside the settings file (ADR
/// 0006) — and, like it, independent of `SAI_ARCHIVE_ROOT`: pointing the
/// archive at a scratch directory does not move the document into
/// whatever is next to it, so a scratch run sets this too. In the
/// person's custody, like the log it is a view of.
File resolveDecisionLogFile({
  required Map<String, String> environment,
  required String operatingSystem,
  SaiIdentity identity = SaiIdentity.stable,
}) {
  final override = environment['SAI_DECISIONS_FILE'];
  if (override != null && override.isNotEmpty) return File(override);
  final data = resolveDataDir(
    environment: environment,
    operatingSystem: operatingSystem,
    identity: identity,
    what: 'the decision document: no SAI_DECISIONS_FILE',
  );
  return File(p.join(data.path, 'decisions.md'));
}

/// Renders every `decision.made` among [events], in chain order, as one
/// Markdown document. Pure: the same lines give the same text. A line
/// whose payload this version cannot read is one entry saying so — the
/// document never fails as a whole. [program] is the command the reader
/// is told to use — `sai_tui` for the stable flavor, `sai_tui-dev` for
/// the dev one (ADR 0019), each with its own archive and document.
///
/// The person's words are prose inside the document's own structure: a
/// line of theirs that would open a heading, a list, a quote, a rule or
/// a fence is escaped, so the numbered entries are the renderer's alone.
String renderDecisionLog(
  Iterable<StoredEvent> events, {
  String program = 'sai_tui',
}) {
  final decisions = [
    for (final stored in events)
      if (stored.event.type == DecisionEventTypes.made) stored,
  ];
  final out = StringBuffer()
    ..writeln("# Decisions made on sai's behalf")
    ..writeln()
    ..writeln(
      'Rendered by `$program decision render` from the `decision.made` lines '
      'of',
    )
    ..writeln(
      'the archive. A view of the log, not a record of its own: do not edit',
    )
    ..writeln(
      'it — record a decision with `$program decision add` and render again.',
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
/// once more, and a tear that stays is the end of the log for this read
/// — the lines before it are the whole of what settled, as the task
/// store's replay and the usage view already hold.
Future<List<StoredEvent>> readDecisions(Archive archive) async {
  for (var attempt = 0; ; attempt++) {
    final decisions = <StoredEvent>[];
    try {
      await for (final stored in archive.events()) {
        if (stored.event.type == DecisionEventTypes.made) {
          decisions.add(stored);
        }
      }
      return decisions;
    } on TornTailError {
      if (attempt > 0) return decisions;
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

/// The day the line was recorded, as the person counts days — local,
/// like `decided` and like the usage view; `ts` itself is UTC.
String _day(StoredEvent stored) =>
    CalendarDate.fromLocal(stored.event.ts).toString();

/// A line that would be Markdown structure at the start of a line — a
/// heading, a list item, a quote, a rule, a fence — with the first mark
/// escaped, so the person's prose stays prose.
final _structure = RegExp(r'^(\s*)([#\-*+>=`~])');

String _prose(String text) => text
    .split('\n')
    .map(
      (line) => line.replaceFirstMapped(_structure, (m) => '${m[1]}\\${m[2]}'),
    )
    .join('\n');

/// One line: whitespace runs, newlines included, become one space.
String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();

void _entry(StringBuffer out, int number, StoredEvent stored) {
  final Decision decision;
  try {
    decision = Decision.fromPayload(stored.event.payload);
  } on FormatException catch (e) {
    out
      ..writeln('## $number. An unreadable decision')
      ..writeln()
      ..writeln(
        'Recorded ${_day(stored)} · `${stored.id}` · ${_oneLine(e.message)}',
      );
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
    ..writeln('**Decision.** ${_prose(decision.decision)}')
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
    ..writeln('**Reasoning.** ${_prose(decision.reasoning)}');
  if (decision.profile != null) {
    out
      ..writeln()
      ..writeln('**Profile.** `${decision.profile}`');
  }
}
