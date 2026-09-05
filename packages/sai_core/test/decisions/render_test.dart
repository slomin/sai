import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

const _header = '''
# Decisions made on sai's behalf

Rendered by `sai_tui decision render` from the `decision.made` lines of
the archive. A view of the log, not a record of its own: do not edit
it — record a decision with `sai_tui decision add` and render again.
The format is § Decisions (#14) of docs/archive/event-log-v0.md in the
sai repository.
''';

void main() {
  final profileId = BlobRef.sha256OfBytes(utf8.encode('profile'));

  StoredEvent stored(
    EventDraft draft, {
    required BlobRef? prev,
    required DateTime ts,
  }) {
    final sealed = Event.seal(draft, prev: prev, ts: ts);
    return StoredEvent(
      id: BlobRef.sha256OfBytes(utf8.encode(sealed.encode())),
      event: sealed,
    );
  }

  test('an empty log says so', () {
    expect(
      renderDecisionLog(const []),
      '$_header\nNo decisions recorded yet.\n',
    );
  });

  test('renders every decision in chain order, and nothing else', () {
    final chat = stored(
      EventDraft(
        type: EventTypes.chatMessage,
        actor: Actor.user,
        source: 'sai/test',
        payload: {'text': 'hello'},
      ),
      prev: null,
      ts: DateTime.utc(2026, 9, 5, 9),
    );
    final first = stored(
      decisionMadeDraft(
        Decision(
          title: 'Name and pronoun',
          decided: const CalendarDate(2026, 8, 23),
          by: 'Jan (guardian)',
          decision: 'She is called sai.',
          alternatives: const ['it', 'they'],
          reasoning: 'A name is needed first.',
          profile: profileId,
        ),
        source: 'sai/test',
      ),
      prev: chat.id,
      ts: DateTime.utc(2026, 9, 5, 10),
    );
    final second = stored(
      decisionMadeDraft(
        Decision(
          title: 'The archive format',
          decided: const CalendarDate(2026, 8, 23),
          by: 'Jan (guardian)',
          decision: 'One JSON Lines log.\n\nNothing is rewritten.',
          reasoning: 'Verifiable with shasum.',
        ),
        source: 'sai/test',
      ),
      prev: first.id,
      ts: DateTime.utc(2026, 9, 5, 11),
    );
    final unreadable = stored(
      EventDraft(
        type: DecisionEventTypes.made,
        actor: Actor.user,
        source: 'sai/test',
        payload: {'title': 'Half a decision', 'decided': '2026-09-06'},
      ),
      prev: second.id,
      ts: DateTime.utc(2026, 9, 6, 8),
    );

    final text = renderDecisionLog([chat, first, second, unreadable]);
    expect(text, '''
$_header
3 decisions; the newest was recorded 2026-09-06.

## 1. Name and pronoun

Decided 2026-08-23 by Jan (guardian) · recorded 2026-09-05 · `${first.id}`

**Decision.** She is called sai.

**Alternatives considered.**

- it
- they

**Reasoning.** A name is needed first.

**Profile.** `$profileId`

## 2. The archive format

Decided 2026-08-23 by Jan (guardian) · recorded 2026-09-05 · `${second.id}`

**Decision.** One JSON Lines log.

Nothing is rewritten.

**Alternatives considered.** None recorded.

**Reasoning.** Verifiable with shasum.

## 3. An unreadable decision

Recorded 2026-09-06 · `${unreadable.id}` · decision.by must be a non-empty string
''');
    // Deterministic: the same lines give the same text.
    expect(renderDecisionLog([chat, first, second, unreadable]), text);
    // One decision reads in the singular.
    expect(
      renderDecisionLog([first]),
      startsWith('$_header\n1 decision, recorded 2026-09-05.\n'),
    );
  });

  test('the document lives beside the archive root', () {
    expect(
      decisionLogFile(Directory('/tmp/scratch/archive')).path,
      '/tmp/scratch/decisions.md',
    );
  });

  test('readDecisions keeps the decision lines only, oldest first', () async {
    final tmp = Directory.systemTemp.createTempSync('sai_decisions_read');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final archive = await Archive.open(Directory('${tmp.path}/archive'));
    addTearDown(archive.close);
    expect(await readDecisions(archive), isEmpty);
    await archive.append(
      EventDraft(
        type: EventTypes.chatMessage,
        actor: Actor.user,
        source: 'sai/test',
        payload: {'text': 'hello'},
      ),
    );
    final first = await archive.append(
      decisionMadeDraft(
        Decision(
          title: 'One',
          decided: const CalendarDate(2026, 9, 5),
          by: 'me',
          decision: 'x',
          reasoning: 'y',
        ),
        source: 'sai/test',
      ),
    );
    final second = await archive.append(
      decisionMadeDraft(
        Decision(
          title: 'Two',
          decided: const CalendarDate(2026, 9, 5),
          by: 'me',
          decision: 'x',
          reasoning: 'y',
        ),
        source: 'sai/test',
      ),
    );
    final read = await readDecisions(archive);
    expect(read.map((s) => s.id), [first.id, second.id]);
  });

  test('writeDecisionLog writes whole, creating the directory', () {
    final tmp = Directory.systemTemp.createTempSync('sai_decisions');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final file = File('${tmp.path}/nested/decisions.md');
    writeDecisionLog(file, 'one\n');
    expect(file.readAsStringSync(), 'one\n');
    writeDecisionLog(file, 'two\n');
    expect(file.readAsStringSync(), 'two\n');
    // Nothing else is left beside it: no temp file of any name.
    expect(file.parent.listSync().map((e) => p.basename(e.path)), [
      'decisions.md',
    ]);
  });

  test('the temp file name carries the pid', () {
    final file = File('/tmp/scratch/decisions.md');
    expect(
      decisionLogTempFile(file).path,
      '/tmp/scratch/decisions.md.$pid.tmp',
    );
  });

  test('a write that fails takes its temp file with it', () {
    final tmp = Directory.systemTemp.createTempSync('sai_decisions');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final file = File('${tmp.path}/decisions.md');
    // A directory where the document goes: the rename cannot land.
    Directory(file.path).createSync();
    expect(
      () => writeDecisionLog(file, 'one\n'),
      throwsA(
        isA<FileSystemException>().having((e) => e.path, 'path', file.path),
      ),
    );
    expect(tmp.listSync().map((e) => p.basename(e.path)), ['decisions.md']);
  });
}
