import 'dart:convert';
import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';
import 'package:sai_tui/cli.dart';
import 'package:test/test.dart';

import 'pump.dart';

void main() {
  late ProviderContainer container;
  late StringBuffer out;
  late StringBuffer err;
  late List<String> prompts;
  late List<String> answers;
  late Directory scratch;

  setUp(() {
    container = testContainer(finishedTasks: null);
    out = StringBuffer();
    err = StringBuffer();
    prompts = [];
    answers = [];
    scratch = Directory.systemTemp.createTempSync('sai_decision_cli_test');
    addTearDown(() => scratch.deleteSync(recursive: true));
  });

  Future<int> run(String line, {ProviderContainer? on}) => runCli(
    line.split(' '),
    container: on ?? container,
    out: out,
    err: err,
    readSecret: (_) => null,
    readLine: (prompt) {
      prompts.add(prompt);
      return answers.isEmpty ? null : answers.removeAt(0);
    },
  );

  File document() => container.read(decisionLogFileProvider);

  Map<String, Object?> onlyDecision() {
    final lines = archiveLines(container);
    expect(lines, hasLength(1));
    final event = jsonDecode(lines.single) as Map<String, Object?>;
    expect(event['type'], 'decision.made');
    expect(event['actor'], 'user');
    expect(event['source'], 'sai/tui');
    expect(event.containsKey('model'), isFalse);
    expect(event.containsKey('refs'), isFalse);
    return event['payload'] as Map<String, Object?>;
  }

  final profileId = BlobRef.sha256OfBytes(utf8.encode('profile'));

  File fromFile(Object json, {String name = 'decision.json'}) {
    final file = File('${scratch.path}/$name');
    file.writeAsStringSync(json is String ? json : jsonEncode(json));
    return file;
  }

  // Fixture words, never a person's: which shade of blue a wall was.
  const fullAnswers = [
    'Which shade of blue',
    '2026-08-23',
    'the guardian',
    'The lighter one.',
    'It was tried first.',
    '.',
    'the darker one',
    'no blue at all',
    '',
    'It reads better in daylight.',
    '.',
  ];

  group('decision add', () {
    test('asks field by field, records one line and renders', () async {
      answers.addAll(fullAnswers);
      expect(await run('decision add'), cliOk);
      expect(err.toString(), isEmpty);
      expect(prompts, [
        'Title: ',
        'Decided (YYYY-MM-DD, empty for today): ',
        'By: ',
        'Decision (end with a line holding only a dot):\n',
        '',
        '',
        'Alternatives, one per line (an empty line ends them):\n',
        '',
        '',
        'Reasoning (end with a line holding only a dot):\n',
        '',
      ]);
      expect(onlyDecision(), {
        'title': 'Which shade of blue',
        'decided': '2026-08-23',
        'by': 'the guardian',
        'decision': 'The lighter one.\nIt was tried first.',
        'alternatives': ['the darker one', 'no blue at all'],
        'reasoning': 'It reads better in daylight.',
      });
      expect(
        out.toString(),
        matches(
          RegExp(
            r'^recorded Which shade of blue as sha256-[a-f0-9]{64}\n'
            r'rendered 1 decision to .*/decisions\.md\n$',
          ),
        ),
      );
      expect(
        out.toString(),
        endsWith('rendered 1 decision to ${document().path}\n'),
      );
      final text = document().readAsStringSync();
      expect(text, startsWith("# Decisions made on sai's behalf\n"));
      expect(text, contains('with `sai_tui decision add` and render again.'));
      expect(text, contains('## 1. Which shade of blue\n'));
      expect(text, contains('- no blue at all\n'));
      expect(text, isNot(contains('**Profile.**')));
    });

    test('a blank line inside the prose is a paragraph', () async {
      answers.addAll([
        'T',
        '',
        'me',
        'First.',
        '',
        'Second.',
        '.',
        '',
        'Why.',
        '.',
      ]);
      expect(await run('decision add'), cliOk);
      final payload = onlyDecision();
      expect(payload['decision'], 'First.\n\nSecond.');
      expect(payload['reasoning'], 'Why.');
      expect(document().readAsStringSync(), contains('First.\n\nSecond.\n'));
    });

    test('an empty day is today; the input may end the last field', () async {
      answers.addAll(['T', '', 'me', 'Because.', '.', '', 'Why not.']);
      expect(await run('decision add'), cliOk);
      final payload = onlyDecision();
      expect(payload['decided'], container.read(todayProvider).toString());
      expect(payload['decision'], 'Because.');
      expect(payload['alternatives'], isEmpty);
      expect(payload['reasoning'], 'Why not.');
      expect(document().readAsStringSync(), contains('None recorded.'));
    });

    test('a second decision is numbered second', () async {
      answers.addAll(fullAnswers);
      expect(await run('decision add'), cliOk);
      out.clear();
      answers.addAll(['Second', '', 'me', 'x', '.', '', 'y', '.']);
      expect(await run('decision add'), cliOk);
      expect(out.toString(), startsWith('recorded Second as sha256-'));
      expect(
        out.toString(),
        endsWith('rendered 2 decisions to ${document().path}\n'),
      );
      expect(archiveLines(container), hasLength(2));
      expect(document().readAsStringSync(), contains('## 2. Second\n'));
    });

    test('--profile names the revision in force, or the one given', () async {
      answers.addAll(fullAnswers);
      expect(await run('decision add --profile'), cliOk);
      expect(onlyDecision()['profile'], {'id': assistantProfileId});
      expect(
        document().readAsStringSync(),
        contains('**Profile.** `$assistantProfileId`\n'),
      );

      answers.addAll(fullAnswers);
      expect(await run('decision add --profile $profileId'), cliOk);
      final lines = archiveLines(container);
      expect(lines, hasLength(2));
      final second = jsonDecode(lines.last) as Map<String, Object?>;
      expect((second['payload'] as Map)['profile'], {
        'id': profileId.toString(),
      });
    });

    test('input ending before a field records nothing', () async {
      answers.add('Only a title');
      expect(await run('decision add'), cliFailed);
      expect(err.toString(), 'sai_tui: input ended before decided\n');
      expect(out.toString(), isEmpty);
      expect(archiveLines(container), isEmpty);
      expect(document().existsSync(), isFalse);
    });

    test('the words are judged before anything is written', () async {
      answers.addAll(['   ', '2026-08-23', 'me', 'x', '.', '', 'y', '.']);
      expect(await run('decision add'), cliFailed);
      expect(
        err.toString(),
        'sai_tui: decision.title must be a non-empty string\n',
      );
      expect(archiveLines(container), isEmpty);

      err.clear();
      final tomorrow = container.read(todayProvider).addDays(1);
      answers.addAll(['T', '$tomorrow', 'me', 'x', '.', '', 'y', '.']);
      expect(await run('decision add'), cliFailed);
      expect(
        err.toString(),
        'sai_tui: decision.decided is after today '
        '(${container.read(todayProvider)})\n',
      );

      err.clear();
      answers.addAll(['T', 'yesterday', 'me', 'x', '.', '', 'y', '.']);
      expect(await run('decision add'), cliFailed);
      expect(
        err.toString(),
        'sai_tui: decision.decided is not a calendar date (YYYY-MM-DD): '
        '"yesterday"\n',
      );
      expect(archiveLines(container), isEmpty);
      expect(document().existsSync(), isFalse);
    });

    test('a decision that cannot be rendered is recorded, once', () async {
      // A directory where the document goes: the rename cannot land.
      Directory(document().path).createSync();
      answers.addAll(fullAnswers);
      expect(await run('decision add'), cliOk);
      // The receipt comes first and alone; the line is in the log.
      expect(
        out.toString(),
        matches(
          RegExp(r'^recorded Which shade of blue as sha256-[a-f0-9]{64}\n$'),
        ),
      );
      expect(
        err.toString(),
        'sai_tui: recorded, but ${document().path} was not rendered: '
        'is a directory; render it with: sai_tui decision render\n',
      );
      expect(onlyDecision()['title'], 'Which shade of blue');
      // No temp file is left beside the document.
      expect(
        document().parent.listSync().map((e) => e.uri.pathSegments.last),
        isNot(contains(endsWith('.tmp'))),
      );

      // The recovery the message names adds no second entry.
      Directory(document().path).deleteSync();
      out.clear();
      err.clear();
      expect(await run('decision render'), cliOk);
      expect(archiveLines(container), hasLength(1));
      final text = document().readAsStringSync();
      expect(text, contains('## 1. Which shade of blue\n'));
      expect(text, isNot(contains('## 2. ')));
    });

    test('the dev flavor writes its own document and names itself', () async {
      final dev = testContainer(
        finishedTasks: null,
        overrides: [identityProvider.overrideWithValue(SaiIdentity.dev)],
      );
      answers.addAll(fullAnswers);
      expect(await run('decision add', on: dev), cliOk);
      final file = dev.read(decisionLogFileProvider);
      expect(out.toString(), endsWith('rendered 1 decision to ${file.path}\n'));
      final text = file.readAsStringSync();
      expect(text, contains('Rendered by `sai_tui-dev decision render`'));
      expect(
        text,
        contains('with `sai_tui-dev decision add` and render again.'),
      );
      expect(text, isNot(contains('`sai_tui decision')));
    });
  });

  group('decision add --from', () {
    test('reads one JSON object, the profile included', () async {
      final file = fromFile({
        'title': 'A written profile',
        'decided': '2026-09-05',
        'by': 'the guardian',
        'decision': 'The standing instructions become a file.',
        'alternatives': ['a constant in the code'],
        'reasoning': 'So they can be read.',
        'profile': {'id': profileId.toString()},
      });
      expect(await run('decision add --from ${file.path}'), cliOk);
      expect(prompts, isEmpty);
      final payload = onlyDecision();
      expect(payload['title'], 'A written profile');
      expect(payload['profile'], {'id': profileId.toString()});
      expect(
        out.toString(),
        startsWith('recorded A written profile as sha256-'),
      );
      expect(
        document().readAsStringSync(),
        contains('**Profile.** `$profileId`\n'),
      );
    });

    test('--profile fills in what the file leaves out', () async {
      final file = fromFile({
        'title': 'A written profile',
        'by': 'the guardian',
        'decision': 'x',
        'reasoning': 'y',
      });
      expect(await run('decision add --from ${file.path} --profile'), cliOk);
      expect(onlyDecision()['profile'], {'id': assistantProfileId});
    });

    test('a missing, unreadable or malformed file is refused', () async {
      final missing = '${scratch.path}/nope.json';
      expect(await run('decision add --from $missing'), cliFailed);
      expect(err.toString(), 'sai_tui: no such file: $missing\n');

      err.clear();
      final bytes = File('${scratch.path}/bytes.json')
        ..writeAsBytesSync([0xff, 0xfe, 0x00]);
      expect(await run('decision add --from ${bytes.path}'), cliFailed);
      expect(
        err.toString(),
        'sai_tui: ${bytes.path}: failed to decode data using encoding '
        "'utf-8'\n",
      );

      err.clear();
      final broken = fromFile('{not json', name: 'broken.json');
      expect(await run('decision add --from ${broken.path}'), cliFailed);
      expect(err.toString(), startsWith('sai_tui: ${broken.path}: '));

      err.clear();
      final list = fromFile([1, 2], name: 'list.json');
      expect(await run('decision add --from ${list.path}'), cliFailed);
      expect(
        err.toString(),
        'sai_tui: ${list.path}: the file must hold one JSON object\n',
      );

      err.clear();
      final typo = fromFile({'title': 'T', 'reasons': 'x'}, name: 'typo.json');
      expect(await run('decision add --from ${typo.path}'), cliFailed);
      expect(err.toString(), 'sai_tui: unknown key in decision: "reasons"\n');
      expect(archiveLines(container), isEmpty);
    });

    test('anything else is a usage error, a flag is never a file', () async {
      expect(await run('decision add --from'), cliUsageError);
      expect(err.toString(), startsWith('sai_tui: --from needs a file\n'));
      err.clear();
      expect(await run('decision add --from --json'), cliUsageError);
      expect(err.toString(), startsWith('sai_tui: --from needs a file\n'));
      err.clear();
      expect(await run('decision add extra'), cliUsageError);
      expect(err.toString(), startsWith('sai_tui: unknown option: extra\n'));
      expect(prompts, isEmpty);
    });
  });

  group('decision render', () {
    test('an empty log renders the document', () async {
      expect(await run('decision render'), cliOk);
      expect(out.toString(), 'rendered 0 decisions to ${document().path}\n');
      expect(
        document().readAsStringSync(),
        contains('No decisions recorded yet.\n'),
      );
    });

    test('- prints to stdout, a path writes there', () async {
      answers.addAll(fullAnswers);
      expect(await run('decision add'), cliOk);
      out.clear();
      expect(await run('decision render -'), cliOk);
      expect(out.toString(), startsWith("# Decisions made on sai's behalf\n"));
      expect(out.toString(), contains('## 1. Which shade of blue\n'));
      expect(out.toString(), document().readAsStringSync());

      out.clear();
      final elsewhere = '${scratch.path}/log.md';
      expect(await run('decision render $elsewhere'), cliOk);
      expect(out.toString(), 'rendered 1 decision to $elsewhere\n');
      expect(File(elsewhere).readAsStringSync(), document().readAsStringSync());
    });

    test('a flag is a usage error, not a file name', () async {
      expect(await run('decision render --help'), cliUsageError);
      expect(err.toString(), startsWith('sai_tui: unknown option: --help\n'));
      expect(File('--help').existsSync(), isFalse);
      err.clear();
      expect(await run('decision render a b'), cliUsageError);
      expect(
        err.toString(),
        startsWith('sai_tui: decision render takes one file at most, or -\n'),
      );
    });
  });

  test('decision alone is a usage error', () async {
    expect(await run('decision'), cliUsageError);
    expect(
      err.toString(),
      startsWith('sai_tui: decision takes add or render: decision\n'),
    );
  });

  test('help lists both commands', () async {
    expect(await run('help'), cliOk);
    expect(
      out.toString(),
      contains(
        'sai_tui decision add [--from <file.json>] [--profile [<sha256-…>]]',
      ),
    );
    expect(out.toString(), contains('sai_tui decision render [<file>|-]'));
  });
}
