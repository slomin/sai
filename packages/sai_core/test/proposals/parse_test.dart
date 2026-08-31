import 'dart:convert';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

const today = CalendarDate(2026, 8, 25);

/// Replays [events] the way the archive would: sealed, chained, one
/// second apart from 2026-08-25T08:00:00Z.
TaskProjection replay(List<TaskEvent> events) {
  var nowMicros = DateTime.utc(2026, 8, 25, 8).microsecondsSinceEpoch;
  BlobRef? prev;
  var projection = TaskProjection.empty;
  for (final event in events) {
    nowMicros += 1000000;
    final ts = DateTime.fromMicrosecondsSinceEpoch(nowMicros, isUtc: true);
    final sealed = Event.seal(
      event.toDraft(source: 'sai/test', by: const Attribution.user()),
      prev: prev,
      ts: ts,
    );
    final id = sealed.deriveId();
    prev = id;
    projection = projection.apply(StoredEvent(id: id, event: sealed));
  }
  return projection;
}

void main() {
  // Three open tasks (t1..t3) and a completed one (no handle).
  late TaskProjection projection;
  late List<TaskId> handles;

  setUp(() {
    projection = replay([
      TaskCreated(title: 'Buy milk'),
      TaskCreated(title: 'Loose thought'),
      TaskCreated(title: 'Dream trip'),
      TaskCreated(title: 'Old chore'),
    ]);
    final done = projection.tasks.values
        .firstWhere((t) => t.title == 'Old chore')
        .id;
    projection = _complete(projection, done);
    handles = renderCatalog(projection, today: today).handles;
    expect(handles, hasLength(3));
  });

  ParsedProposal parse(String text) => parseProposalText(
    text,
    handles: handles,
    projection: projection,
    today: today,
  );

  String suggestion({
    String kind = 'schedule',
    String task = 't1',
    String when = '',
    String deadline = '',
    List<String> parts = const [],
    String reason = 'because',
  }) => jsonEncode({
    'suggestions': [
      {
        'kind': kind,
        'task': task,
        'when': when,
        'deadline': deadline,
        'parts': parts,
        'reason': reason,
      },
    ],
    'note': 'a note',
  });

  test('a full proposal resolves handles, dates and titles', () {
    final parsed = parse(
      jsonEncode({
        'suggestions': [
          {
            'kind': 'schedule',
            'task': 't1',
            'when': 'someday',
            'deadline': '',
            'parts': <String>[],
            'reason': 'later is fine',
          },
          {
            'kind': 'deadline',
            'task': 't2',
            'when': '',
            'deadline': 'tomorrow',
            'parts': <String>[],
            'reason': 'needs an edge',
          },
          {
            'kind': 'split',
            'task': 't3',
            'when': '',
            'deadline': '',
            'parts': [' first ', 'second'],
            'reason': 'two sittings',
          },
        ],
        'note': 'three ideas',
      }),
    );
    expect(parsed.note, 'three ideas');
    expect(parsed.items, hasLength(3));

    final schedule = parsed.items[0];
    expect(schedule.kind, SuggestionKind.schedule);
    expect(schedule.target, handles[0]);
    expect(schedule.targetTitle, 'Buy milk');
    expect(schedule.when, TaskWhen.someday);
    expect(schedule.headline, 'Move to Someday');
    expect(schedule.status, SuggestionStatus.pending);
    expect(schedule.fingerprint, projection.task(handles[0])!.modifiedAt);

    final deadline = parsed.items[1];
    expect(deadline.kind, SuggestionKind.deadline);
    expect(deadline.deadline, today.addDays(1));
    expect(deadline.headline, 'Deadline 2026-08-26');

    final split = parsed.items[2];
    expect(split.parts, ['first', 'second'], reason: 'parts are trimmed');
    expect(split.headline, 'Split into 2');
  });

  test('today, tomorrow, anytime and dates resolve concretely', () {
    expect(
      parse(suggestion(when: 'today')).items.single.when,
      const TaskWhen.date(today),
    );
    expect(
      parse(suggestion(when: 'tomorrow')).items.single.when,
      TaskWhen.date(today.addDays(1)),
    );
    expect(parse(suggestion(when: 'anytime')).items.single.when, TaskWhen.none);
    expect(
      parse(suggestion(when: '2026-09-05')).items.single.when,
      const TaskWhen.date(CalendarDate(2026, 9, 5)),
    );
    final cleared = parse(suggestion(kind: 'deadline', deadline: 'none'))
        .items
        .single;
    expect(cleared.deadline, isNull);
    expect(cleared.headline, 'Clear the deadline');
  });

  test('the fake round-trips through the parser', () {
    final render = renderCatalog(projection, today: today);
    final request = LlmRequest(
      messages: [
        const LlmMessage(LlmRole.system, 'profile'),
        LlmMessage(LlmRole.system, render.text),
        const LlmMessage(LlmRole.user, 'propose'),
      ],
      responseSchema: proposalResponseSchema,
    );
    final parsed = parse(fakeProposal(request));
    expect(parsed.items, hasLength(3));
    expect(parsed.items[0].when, TaskWhen.someday);
    expect(parsed.items[1].deadline, today.addDays(1));
    expect(parsed.items[2].parts, hasLength(2));
  });

  group('refusals', () {
    void refuses(String text, String reason) {
      expect(
        () => parse(text),
        throwsA(
          isA<ProposalFormatError>().having((e) => e.reason, 'reason', reason),
        ),
      );
    }

    test('not JSON', () => refuses('nope', 'not JSON'));
    test('not an object', () => refuses('[1]', 'not an object'));
    test(
      'unknown top-level key',
      () => refuses('{"suggestions":[],"note":"","x":1}', "unknown key 'x'"),
    );
    test('missing note', () => refuses('{"suggestions":[]}', "missing 'note'"));
    test(
      'missing suggestions',
      () => refuses('{"note":""}', "missing 'suggestions'"),
    );
    test('too many suggestions', () {
      final many = jsonEncode({
        'suggestions': List.filled(9, {
          'kind': 'schedule',
          'task': 't1',
          'when': 'someday',
          'deadline': '',
          'parts': <String>[],
          'reason': '',
        }),
        'note': '',
      });
      refuses(many, 'too many suggestions');
    });
    test(
      'unknown handle',
      () => refuses(
        suggestion(task: 't9', when: 'someday'),
        "unknown handle 't9'",
      ),
    );
    test(
      'handle-shaped nonsense',
      () => refuses(suggestion(task: 'x1', when: 'someday'), "bad handle 'x1'"),
    );
    test('a completed task cannot be targeted', () {
      final done = projection.tasks.values
          .firstWhere((t) => t.title == 'Old chore')
          .id;
      expect(
        () => parseProposalText(
          suggestion(when: 'someday'),
          handles: [done],
          projection: projection,
          today: today,
        ),
        throwsA(
          isA<ProposalFormatError>().having(
            (e) => e.reason,
            'reason',
            "'t1' is not an open task",
          ),
        ),
      );
    });
    test('duplicate kind and target', () {
      final twice = jsonEncode({
        'suggestions': [
          for (var i = 0; i < 2; i++)
            {
              'kind': 'schedule',
              'task': 't1',
              'when': 'someday',
              'deadline': '',
              'parts': <String>[],
              'reason': '',
            },
        ],
        'note': '',
      });
      refuses(twice, "duplicate suggestion for 't1'");
    });
    test(
      'a handle too big for an int is unknown, never a crash',
      () => refuses(
        suggestion(task: 't999999999999999999999999999999', when: 'someday'),
        "unknown handle 't999999999999999999999999999999'",
      ),
    );
    test(
      'bad when word',
      () => refuses(suggestion(when: 'soon'), "bad when 'soon'"),
    );
    test(
      'unreal date',
      () => refuses(suggestion(when: '2026-13-99'), "bad when '2026-13-99'"),
    );
    test(
      'empty when on a schedule',
      () => refuses(suggestion(), "bad when ''"),
    );
    test(
      'bad deadline word',
      () => refuses(
        suggestion(kind: 'deadline', deadline: 'someday'),
        "bad deadline 'someday'",
      ),
    );
    test(
      'a split needs two parts',
      () => refuses(
        suggestion(kind: 'split', parts: ['only']),
        'a split needs at least two parts',
      ),
    );
    test(
      'a blank part',
      () => refuses(
        suggestion(kind: 'split', parts: ['a', '  ']),
        'a split part is blank',
      ),
    );
    test(
      'a repeated part',
      () => refuses(
        suggestion(kind: 'split', parts: ['a', 'a ']),
        'a split part repeats',
      ),
    );
  });
}

/// Completes [task] on top of [base], continuing the chain.
TaskProjection _complete(TaskProjection base, TaskId task) {
  final sealed = Event.seal(
    TaskCompleted(task)
        .toDraft(source: 'sai/test', by: const Attribution.user()),
    prev: base.lastEventId,
    ts: DateTime.utc(2026, 8, 25, 9),
  );
  return base.apply(StoredEvent(id: sealed.deriveId(), event: sealed));
}
