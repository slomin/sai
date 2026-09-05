import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

/// The fixture the chat answers about (#34): two due today, two coming
/// up on different days (one of them an Inbox task with a deadline — the
/// view union), one someday, one done. Built as events, replayed pure.
TaskProjection fixture() {
  var nowMicros = DateTime.utc(2026, 8, 25, 8).microsecondsSinceEpoch;
  BlobRef? prev;
  var projection = TaskProjection.empty;
  void add(TaskEvent event) {
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

  const today = CalendarDate(2026, 8, 25);
  add(TaskCreated(title: 'Call mom', when: const TaskWhen.date(today)));
  add(TaskCreated(title: 'Pay rent', deadline: today));
  add(
    TaskCreated(
      title: 'Ring dentist',
      when: const TaskWhen.date(CalendarDate(2026, 8, 26)),
    ),
  );
  add(
    TaskCreated(
      title: 'Renew passport',
      deadline: const CalendarDate(2026, 9, 1),
    ),
  );
  add(TaskCreated(title: 'Learn the violin', when: TaskWhen.someday));
  add(TaskCreated(title: 'Old thing', when: const TaskWhen.date(today)));
  final old = projection.tasks.values.singleWhere(
    (t) => t.title == 'Old thing',
  );
  add(TaskCompleted(old.id));
  return projection;
}

const today = CalendarDate(2026, 8, 25);

const goldenTaskContext =
    'Today is 2026-08-25.\n'
    'Today (2):\n'
    '- Call mom @today\n'
    '- Pay rent !today\n'
    'Upcoming (2):\n'
    '2026-08-26:\n'
    '- Ring dentist @tomorrow\n'
    '2026-09-01:\n'
    '- Renew passport !2026-09-01';

void main() {
  group('taskContextFor', () {
    test('renders Today and Upcoming as the clients show them', () {
      expect(taskContextFor(fixture(), today), goldenTaskContext);
    });

    test('empty lists say so', () {
      expect(
        taskContextFor(TaskProjection.empty, today),
        'Today is 2026-08-25.\nToday (0): none\nUpcoming (0): none',
      );
    });

    test('a day cap keeps the nearest days and states the cut', () {
      expect(
        taskContextFor(fixture(), today, upcomingDays: 1),
        'Today is 2026-08-25.\n'
        'Today (2):\n'
        '- Call mom @today\n'
        '- Pay rent !today\n'
        'Upcoming (1):\n'
        '2026-08-26:\n'
        '- Ring dentist @tomorrow\n'
        '(1 more day not shown)',
      );
      expect(
        taskContextFor(fixture(), today, upcomingDays: 0),
        'Today is 2026-08-25.\n'
        'Today (2):\n'
        '- Call mom @today\n'
        '- Pay rent !today\n'
        'Upcoming (0): none\n'
        '(2 more days not shown)',
      );
    });

    test('is deterministic', () {
      expect(
        taskContextFor(fixture(), today),
        taskContextFor(fixture(), today),
      );
    });
  });

  group('assembleContext', () {
    test('profile, history, draft — and the list apart', () {
      final out = assembleContext(
        profile: assistantProfile,
        projection: fixture(),
        today: today,
        history: const [
          LlmMessage(LlmRole.user, 'hi'),
          LlmMessage(LlmRole.assistant, 'hello'),
        ],
        draft: '  what is due today?  ',
      );
      final r = out.request;
      expect(r.messages.map((m) => m.toJson()), [
        {'role': 'system', 'text': assistantProfile},
        {'role': 'user', 'text': 'hi'},
        {'role': 'assistant', 'text': 'hello'},
        {'role': 'user', 'text': 'what is due today?'},
      ]);
      expect(r.taskContext, goldenTaskContext);
      expect(r.maxTokens, defaultContextBudget.replyReserve);
      expect(out.dropped, isEmpty);
      // As sent, the list is a system message right after the profile.
      expect(r.sent[1].role, LlmRole.system);
      expect(r.sent[1].text, goldenTaskContext);
      expect(
        out.estimatedTokens,
        r.sent.fold(0, (n, m) => n + estimateTokens(m.text)),
      );
    });

    test('memory is a second system message', () {
      final out = assembleContext(
        profile: 'p',
        memory: 'yesterday we planned the week',
        projection: TaskProjection.empty,
        today: today,
        history: const [],
        draft: 'x',
      );
      expect(out.request.messages.map((m) => m.text), [
        'p',
        'yesterday we planned the week',
        'x',
      ]);
    });

    test('refuses a blank draft, an empty profile or memory', () {
      AssembledContext call({
        String draft = 'x',
        String profile = 'p',
        String? memory,
      }) => assembleContext(
        profile: profile,
        memory: memory,
        projection: TaskProjection.empty,
        today: today,
        history: const [],
        draft: draft,
      );
      expect(() => call(draft: '  '), throwsArgumentError);
      expect(() => call(profile: ''), throwsArgumentError);
      expect(() => call(memory: ''), throwsArgumentError);
    });

    test('the same inputs give the same request and hash', () {
      AssembledContext go() => assembleContext(
        profile: assistantProfile,
        projection: fixture(),
        today: today,
        history: const [LlmMessage(LlmRole.user, 'a')],
        draft: 'b',
      );
      expect(contextHash(go().request.sent), contextHash(go().request.sent));
    });

    group('budget', () {
      // Every text below is short, so the estimate is dominated by the
      // pieces the test grows on purpose; 'x' * 400 is ~100 tokens.
      final big = 'x' * 400;

      test('cuts the oldest turns first, in pairs', () {
        final out = assembleContext(
          profile: 'p',
          projection: TaskProjection.empty,
          today: today,
          history: [
            LlmMessage(LlmRole.user, big),
            LlmMessage(LlmRole.assistant, big),
            LlmMessage(LlmRole.user, big),
            LlmMessage(LlmRole.assistant, big),
            const LlmMessage(LlmRole.user, 'recent'),
            const LlmMessage(LlmRole.assistant, 'yes'),
          ],
          draft: 'now',
          budget: const ContextBudget(maxTokens: 300, replyReserve: 100),
        );
        expect(out.dropped, ['turns:4']);
        expect(out.request.messages.map((m) => m.text), [
          'p',
          'recent',
          'yes',
          'now',
        ]);
      });

      test('then Upcoming days from the farthest back', () {
        final out = assembleContext(
          profile: 'p',
          projection: fixture(),
          today: today,
          history: [LlmMessage(LlmRole.user, big)],
          draft: 'now',
          // Whole list 40 tokens, one day 36, none 28; profile and draft 1 each.
          budget: const ContextBudget(maxTokens: 140, replyReserve: 100),
        );
        expect(out.dropped, ['turns:1', 'upcoming:2026-09-01']);
        expect(out.request.taskContext, contains('(1 more day not shown)'));
        expect(out.request.taskContext, contains('Ring dentist'));
        expect(out.request.taskContext, isNot(contains('Renew passport')));
      });

      test('then memory; Today and the profile never', () {
        final out = assembleContext(
          profile: 'p',
          memory: big,
          projection: fixture(),
          today: today,
          history: const [],
          draft: 'now',
          budget: const ContextBudget(maxTokens: 140, replyReserve: 100),
        );
        expect(out.dropped, [
          'upcoming:2026-09-01',
          'upcoming:2026-08-26',
          'memory',
        ]);
        expect(out.request.taskContext, contains('Call mom'));
        expect(out.request.messages.map((m) => m.text), ['p', 'now']);
      });

      test('past that it refuses', () {
        expect(
          () => assembleContext(
            profile: big,
            projection: fixture(),
            today: today,
            history: const [],
            draft: 'now',
            budget: const ContextBudget(maxTokens: 120, replyReserve: 100),
          ),
          throwsA(
            isA<ContextBudgetError>().having(
              (e) => e.toString(),
              'message',
              contains('the budget allows 20'),
            ),
          ),
        );
      });
    });

    group('catalog shape (#105)', () {
      test('carries the whole catalog, provenance and all', () {
        final out = assembleContext(
          profile: assistantProfile,
          projection: fixture(),
          today: today,
          history: const [],
          draft: 'what did I finish?',
          shape: TaskContextShape.catalog,
        );
        expect(out.request.taskContext, taskCatalog(fixture(), today: today));
        expect(out.request.taskContextProvenance, TaskProvenance.catalog);
        expect(out.request.taskContext, contains('Old thing'));
        expect(out.dropped, isEmpty);
      });

      test('cuts turns then memory, never the catalog', () {
        final big = 'x' * 400;
        final catalog = taskCatalog(fixture(), today: today);
        final need =
            estimateTokens('p') +
            estimateTokens('now') +
            estimateTokens(catalog);
        final out = assembleContext(
          profile: 'p',
          memory: big,
          projection: fixture(),
          today: today,
          history: [
            LlmMessage(LlmRole.user, big),
            LlmMessage(LlmRole.assistant, big),
          ],
          draft: 'now',
          budget: ContextBudget(maxTokens: need + 110, replyReserve: 100),
          shape: TaskContextShape.catalog,
        );
        expect(out.dropped, ['turns:2', 'memory']);
        expect(out.request.taskContext, catalog);
      });

      test('past that it refuses rather than shrink the catalog', () {
        expect(
          () => assembleContext(
            profile: 'p',
            projection: fixture(),
            today: today,
            history: const [],
            draft: 'now',
            budget: const ContextBudget(maxTokens: 120, replyReserve: 100),
            shape: TaskContextShape.catalog,
          ),
          throwsA(isA<ContextBudgetError>()),
        );
      });
    });

    group('the exact-size preflight (#105)', () {
      // A window so large only the byte ceiling is in play. JSON doubles
      // a quote character, so the estimate (raw bytes / 4) stays far
      // under the token budget while the encoded payload crosses the cap.
      const roomy = ContextBudget(maxTokens: 1000000, replyReserve: 4096);
      final heavy = '"' * 400000;

      test('escape-heavy history is cut by encoded size', () {
        final out = assembleContext(
          profile: 'p',
          projection: TaskProjection.empty,
          today: today,
          history: [
            LlmMessage(LlmRole.user, heavy),
            LlmMessage(LlmRole.assistant, heavy),
            const LlmMessage(LlmRole.user, 'recent'),
            const LlmMessage(LlmRole.assistant, 'yes'),
          ],
          draft: 'now',
          budget: roomy,
        );
        expect(out.dropped, ['turns:2']);
        expect(
          recordedRequestBytes(out.request),
          lessThanOrEqualTo(maxRecordedTextBytes),
        );
      });

      test('past every cut it refuses with the exact size', () {
        expect(
          () => assembleContext(
            profile: '"' * 600000,
            projection: TaskProjection.empty,
            today: today,
            history: const [],
            draft: 'now',
            budget: roomy,
          ),
          throwsA(
            isA<ContextSizeError>()
                .having(
                  (e) => e.bytes,
                  'bytes',
                  greaterThan(maxRecordedTextBytes),
                )
                .having((e) => e.limit, 'limit', maxRecordedTextBytes)
                .having(
                  (e) => e.toString(),
                  'message',
                  contains('once recorded'),
                ),
          ),
        );
      });
    });
  });

  test('estimateTokens rounds four bytes up to a token', () {
    expect(estimateTokens(''), 0);
    expect(estimateTokens('abcd'), 1);
    expect(estimateTokens('abcde'), 2);
    expect(estimateTokens('ż'), 1); // two bytes
  });
}
