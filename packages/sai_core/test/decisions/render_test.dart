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

  /// The day a UTC instant falls on where the test runs — what the
  /// document prints as "recorded", like `decided`, a local day.
  String local(DateTime utc) => CalendarDate.fromLocal(utc).toString();

  // Noon UTC: the same local day everywhere the suite runs.
  final noon5 = DateTime.utc(2026, 9, 5, 12);
  final one5 = DateTime.utc(2026, 9, 5, 13);
  final noon6 = DateTime.utc(2026, 9, 6, 12);

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
          title: 'Which shade of blue',
          decided: const CalendarDate(2026, 8, 23),
          by: 'the guardian',
          decision: 'The lighter one.',
          alternatives: const ['the darker one', 'no blue at all'],
          reasoning: 'It reads better in daylight.',
          profile: profileId,
        ),
        source: 'sai/test',
      ),
      prev: chat.id,
      ts: noon5,
    );
    final second = stored(
      decisionMadeDraft(
        Decision(
          title: 'Which typeface',
          decided: const CalendarDate(2026, 8, 23),
          by: 'the guardian',
          decision: 'The one with the taller x-height.\n\nSerifs stay.',
          reasoning: "It reads at arm's length.",
        ),
        source: 'sai/test',
      ),
      prev: first.id,
      ts: one5,
    );
    final unreadable = stored(
      EventDraft(
        type: DecisionEventTypes.made,
        actor: Actor.user,
        source: 'sai/test',
        payload: {'title': 'Half a decision', 'decided': '2026-09-06'},
      ),
      prev: second.id,
      ts: noon6,
    );

    final text = renderDecisionLog([chat, first, second, unreadable]);
    expect(text, '''
$_header
3 decisions; the newest was recorded ${local(noon6)}.

## 1. Which shade of blue

Decided 2026-08-23 by the guardian · recorded ${local(noon5)} · `${first.id}`

**Decision.** The lighter one.

**Alternatives considered.**

- the darker one
- no blue at all

**Reasoning.** It reads better in daylight.

**Profile.** `$profileId`

## 2. Which typeface

Decided 2026-08-23 by the guardian · recorded ${local(one5)} · `${second.id}`

**Decision.** The one with the taller x-height.

Serifs stay.

**Alternatives considered.** None recorded.

**Reasoning.** It reads at arm's length.

## 3. An unreadable decision

Recorded ${local(noon6)} · `${unreadable.id}` · decision.by must be a non-empty string
''');
    // Deterministic: the same lines give the same text.
    expect(renderDecisionLog([chat, first, second, unreadable]), text);
    // One decision reads in the singular.
    expect(
      renderDecisionLog([first]),
      startsWith('$_header\n1 decision, recorded ${local(noon5)}.\n'),
    );
  });

  test('the recorded day is the local day of ts, like decided', () {
    // 23:30 UTC on the 5th is the 6th east of Greenwich: the document
    // follows the person's calendar, not the wire's.
    final late = DateTime.utc(2026, 9, 5, 23, 30);
    final line = stored(
      decisionMadeDraft(
        Decision(
          title: 'Late',
          decided: CalendarDate.fromLocal(late),
          by: 'the guardian',
          decision: 'x',
          reasoning: 'y',
        ),
        source: 'sai/test',
      ),
      prev: null,
      ts: late,
    );
    expect(
      renderDecisionLog([line]),
      contains(
        'Decided ${local(late)} by the guardian · recorded ${local(late)}',
      ),
    );
  });

  test("the person's prose cannot open structure of its own", () {
    final line = stored(
      decisionMadeDraft(
        Decision(
          title: 'Real',
          decided: const CalendarDate(2026, 9, 5),
          by: 'the guardian',
          decision:
              'Cobalt.\n\n## 9. Forged entry\n\nDecided 1999-01-01 by nobody',
          reasoning: '- not a list\n> not a quote\n```\nnot a fence\n===',
        ),
        source: 'sai/test',
      ),
      prev: null,
      ts: noon5,
    );
    final text = renderDecisionLog([line]);
    final headings = RegExp(r'^## ', multiLine: true).allMatches(text).length;
    expect(
      headings,
      1,
      reason: 'the renderer numbers the entries, nobody else',
    );
    expect(text, contains('\n\\## 9. Forged entry\n'));
    expect(
      text,
      contains(
        '**Reasoning.** \\- not a list\n\\> not a quote\n\\```\nnot a fence\n\\===\n',
      ),
    );
    // The words themselves are untouched.
    expect(text, contains('Decided 1999-01-01 by nobody'));
  });

  test('an unreadable line cannot open structure through its reason', () {
    final line = stored(
      EventDraft(
        type: DecisionEventTypes.made,
        actor: Actor.user,
        source: 'sai/test',
        payload: {
          'title': 'x',
          'decided':
              '2026-01-01 \n\n## 99. Forged\n\nDecided 2020-01-01 by nobody',
          'by': 'y',
          'decision': 'z',
          'reasoning': 'w',
        },
      ),
      prev: null,
      ts: noon5,
    );
    final text = renderDecisionLog([line]);
    expect(RegExp(r'^## ', multiLine: true).allMatches(text).length, 1);
    expect(
      text,
      contains(
        '· decision.decided is not a calendar date (YYYY-MM-DD): '
        '"2026-01-01 ## 99. Forged Decided 2020-01-01 by nobody"\n',
      ),
    );
  });

  test('the header names the command of the flavor that rendered it', () {
    final dev = renderDecisionLog(const [], program: 'sai_tui-dev');
    expect(dev, contains('Rendered by `sai_tui-dev decision render`'));
    expect(dev, contains('with `sai_tui-dev decision add` and render again.'));
    expect(dev, isNot(contains('`sai_tui decision')));
  });

  group('resolveDecisionLogFile', () {
    test('follows SAI_DECISIONS_FILE, else the data directory', () {
      expect(
        resolveDecisionLogFile(
          environment: {'HOME': '/Users/x', 'SAI_DECISIONS_FILE': '/tmp/d.md'},
          operatingSystem: 'macos',
        ).path,
        '/tmp/d.md',
      );
      expect(
        resolveDecisionLogFile(
          environment: {'HOME': '/Users/x'},
          operatingSystem: 'macos',
        ).path,
        '/Users/x/Library/Application Support/sai/decisions.md',
      );
      expect(
        resolveDecisionLogFile(
          environment: {'HOME': '/Users/x'},
          operatingSystem: 'macos',
          identity: SaiIdentity.dev,
        ).path,
        '/Users/x/Library/Application Support/sai-dev/decisions.md',
      );
      expect(
        resolveDecisionLogFile(
          environment: {'HOME': '/home/x', 'XDG_DATA_HOME': '/data'},
          operatingSystem: 'linux',
        ).path,
        '/data/sai/decisions.md',
      );
    });

    test('a scratch archive root does not move the document', () {
      // ADR 0006's rule for the settings file, and this file's: the
      // archive root says nothing about where the document goes.
      expect(
        resolveDecisionLogFile(
          environment: {'HOME': '/Users/x', 'SAI_ARCHIVE_ROOT': '/tmp/a'},
          operatingSystem: 'macos',
        ).path,
        '/Users/x/Library/Application Support/sai/decisions.md',
      );
    });
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
          by: 'the guardian',
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
          by: 'the guardian',
          decision: 'x',
          reasoning: 'y',
        ),
        source: 'sai/test',
      ),
    );
    final read = await readDecisions(archive);
    expect(read.map((s) => s.id), [first.id, second.id]);

    // A tear that stays is the end of the log for this read: what
    // settled before it is the whole of it, as the task store holds.
    final day = Directory('${tmp.path}/archive/events')
        .listSync()
        .whereType<File>()
        .single;
    day.writeAsStringSync('{"torn', mode: FileMode.append, flush: true);
    final settled = await readDecisions(archive);
    expect(settled.map((s) => s.id), [first.id, second.id]);
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
}
