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

  Future<int> run(String line) => runCli(
    line.split(' '),
    container: container,
    out: out,
    err: err,
    readSecret: (_) => null,
    readLine: (prompt) {
      prompts.add(prompt);
      return answers.isEmpty ? null : answers.removeAt(0);
    },
  );

  File document() =>
      File('${container.read(archiveRootProvider).parent.path}/decisions.md');

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

  const fullAnswers = [
    'Name and pronoun',
    '2026-08-23',
    'Jan (guardian)',
    'She is called sai.',
    'Lowercase.',
    '',
    'it',
    'they',
    '',
    'A name is needed first.',
    '',
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
        'Decision (end with an empty line):\n',
        '',
        '',
        'Alternatives, one per line (an empty line ends them):\n',
        '',
        '',
        'Reasoning (end with an empty line):\n',
        '',
      ]);
      expect(onlyDecision(), {
        'title': 'Name and pronoun',
        'decided': '2026-08-23',
        'by': 'Jan (guardian)',
        'decision': 'She is called sai.\nLowercase.',
        'alternatives': ['it', 'they'],
        'reasoning': 'A name is needed first.',
      });
      expect(
        out.toString(),
        matches(
          RegExp(
            r'^recorded 1\. Name and pronoun as sha256-[a-f0-9]{64}\n'
            r'rendered .*/decisions\.md\n$',
          ),
        ),
      );
      expect(out.toString(), endsWith('rendered ${document().path}\n'));
      final text = document().readAsStringSync();
      expect(text, startsWith("# Decisions made on sai's behalf\n"));
      expect(text, contains('## 1. Name and pronoun\n'));
      expect(text, contains('- they\n'));
      expect(text, isNot(contains('**Profile.**')));
    });

    test('an empty day is today; the input may end the last field', () async {
      answers.addAll(['T', '', 'me', 'Because.', '', '', 'Why not.']);
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
      answers.addAll(['Second', '', 'me', 'x', '', '', 'y', '']);
      expect(await run('decision add'), cliOk);
      expect(out.toString(), startsWith('recorded 2. Second as sha256-'));
      expect(archiveLines(container), hasLength(2));
      expect(document().readAsStringSync(), contains('## 2. Second\n'));
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
      answers.addAll(['   ', '2026-08-23', 'me', 'x', '', '', 'y', '']);
      expect(await run('decision add'), cliFailed);
      expect(
        err.toString(),
        'sai_tui: decision.title must be a non-empty string\n',
      );
      expect(archiveLines(container), isEmpty);

      err.clear();
      final tomorrow = container.read(todayProvider).addDays(1);
      answers.addAll(['T', '$tomorrow', 'me', 'x', '', '', 'y', '']);
      expect(await run('decision add'), cliFailed);
      expect(
        err.toString(),
        'sai_tui: decision.decided is after today '
        '(${container.read(todayProvider)})\n',
      );

      err.clear();
      answers.addAll(['T', 'yesterday', 'me', 'x', '', '', 'y', '']);
      expect(await run('decision add'), cliFailed);
      expect(
        err.toString(),
        'sai_tui: decision.decided is not a calendar date (YYYY-MM-DD): '
        '"yesterday"\n',
      );
      expect(archiveLines(container), isEmpty);
      expect(document().existsSync(), isFalse);
    });
  });

  group('decision add --from', () {
    test('reads one JSON object, the profile included', () async {
      final file = fromFile({
        'title': 'Profile v0',
        'decided': '2026-09-05',
        'by': 'Jan (guardian)',
        'decision': 'A written profile.',
        'alternatives': ['a constant in the code'],
        'reasoning': 'So she can be read.',
        'profile': {'id': profileId.toString()},
      });
      expect(await run('decision add --from ${file.path}'), cliOk);
      expect(prompts, isEmpty);
      final payload = onlyDecision();
      expect(payload['title'], 'Profile v0');
      expect(payload['profile'], {'id': profileId.toString()});
      expect(out.toString(), startsWith('recorded 1. Profile v0 as sha256-'));
      expect(
        document().readAsStringSync(),
        contains('**Profile.** `$profileId`\n'),
      );
    });

    test('a missing or malformed file is refused', () async {
      final missing = '${scratch.path}/nope.json';
      expect(await run('decision add --from $missing'), cliFailed);
      expect(err.toString(), 'sai_tui: no such file: $missing\n');

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

    test('anything else is a usage error', () async {
      expect(await run('decision add --from'), cliUsageError);
      expect(
        err.toString(),
        startsWith(
          'sai_tui: decision add takes --from <file.json>, or nothing\n',
        ),
      );
      err.clear();
      expect(await run('decision add extra'), cliUsageError);
      expect(prompts, isEmpty);
    });
  });

  group('decision render', () {
    test('an empty log renders beside the archive', () async {
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
      expect(out.toString(), contains('## 1. Name and pronoun\n'));
      expect(out.toString(), document().readAsStringSync());

      out.clear();
      final elsewhere = '${scratch.path}/log.md';
      expect(await run('decision render $elsewhere'), cliOk);
      expect(out.toString(), 'rendered 1 decisions to $elsewhere\n');
      expect(File(elsewhere).readAsStringSync(), document().readAsStringSync());
    });

    test('two arguments are a usage error', () async {
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
      contains('sai_tui decision add [--from <file.json>]'),
    );
    expect(out.toString(), contains('sai_tui decision render [<file>|-]'));
  });
}
