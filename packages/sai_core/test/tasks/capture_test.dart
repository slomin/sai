import 'dart:io';

import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  const today = CalendarDate(2026, 8, 24);
  const tomorrow = CalendarDate(2026, 8, 25);

  QuickCapture? parse(String line) => parseQuickCapture(line, today: today);

  group('parseQuickCapture', () {
    test('a plain line is the title, bound for the Inbox', () {
      expect(parse('Buy oat milk'), const QuickCapture(title: 'Buy oat milk'));
    });

    test('surrounding whitespace is trimmed, inner spacing kept', () {
      expect(
        parse('  fix  the   door  '),
        const QuickCapture(title: 'fix  the   door'),
      );
    });

    test('when tokens', () {
      expect(
        parse('Call mom @today'),
        const QuickCapture(title: 'Call mom', when: TaskWhen.date(today)),
      );
      expect(
        parse('Call mom @tomorrow'),
        const QuickCapture(title: 'Call mom', when: TaskWhen.date(tomorrow)),
      );
      expect(
        parse('Learn the violin @someday'),
        const QuickCapture(title: 'Learn the violin', when: TaskWhen.someday),
      );
      expect(
        parse('Book flights @2026-09-01'),
        const QuickCapture(
          title: 'Book flights',
          when: TaskWhen.date(CalendarDate(2026, 9, 1)),
        ),
      );
    });

    test('deadline tokens', () {
      expect(
        parse('Pay rent !2026-09-01'),
        const QuickCapture(
          title: 'Pay rent',
          deadline: CalendarDate(2026, 9, 1),
        ),
      );
      expect(
        parse('Pay rent !today'),
        const QuickCapture(title: 'Pay rent', deadline: today),
      );
      expect(
        parse('Pay rent !tomorrow'),
        const QuickCapture(title: 'Pay rent', deadline: tomorrow),
      );
    });

    test('both kinds combine, in either order', () {
      const expected = QuickCapture(
        title: 'File taxes',
        when: TaskWhen.date(today),
        deadline: CalendarDate(2026, 9, 1),
      );
      expect(parse('File taxes @today !2026-09-01'), expected);
      expect(parse('File taxes !2026-09-01 @today'), expected);
    });

    test('keywords are case-insensitive', () {
      expect(
        parse('x @TODAY'),
        const QuickCapture(title: 'x', when: TaskWhen.date(today)),
      );
      expect(
        parse('x !Tomorrow'),
        const QuickCapture(title: 'x', deadline: tomorrow),
      );
    });

    test('a token mid-line stays in the title', () {
      expect(
        parse('call @today mom'),
        const QuickCapture(title: 'call @today mom'),
      );
    });

    test('an unrecognized trailing word stops the scan', () {
      expect(
        parse('x @nope @today'),
        const QuickCapture(title: 'x @nope', when: TaskWhen.date(today)),
      );
    });

    test('a repeated kind stops the scan', () {
      expect(
        parse('x @today @tomorrow'),
        const QuickCapture(title: 'x @today', when: TaskWhen.date(tomorrow)),
      );
    });

    test('an invalid date is not a token', () {
      expect(
        parse('x @2026-13-01'),
        const QuickCapture(title: 'x @2026-13-01'),
      );
      expect(parse('x @2026-9-1'), const QuickCapture(title: 'x @2026-9-1'));
      expect(
        parse('x !2026-02-30'),
        const QuickCapture(title: 'x !2026-02-30'),
      );
    });

    test('a glued token is title text', () {
      expect(parse('milk@today'), const QuickCapture(title: 'milk@today'));
    });

    test('there is no !someday', () {
      expect(parse('x !someday'), const QuickCapture(title: 'x !someday'));
    });

    test('a line of nothing but tokens is a title verbatim', () {
      expect(parse('@today'), const QuickCapture(title: '@today'));
      expect(
        parse('!today @today'),
        const QuickCapture(title: '!today @today'),
      );
    });

    test('a blank line captures nothing', () {
      expect(parse(''), isNull);
      expect(parse('   '), isNull);
      expect(parse('\t\n'), isNull);
    });

    test('unicode titles survive', () {
      expect(
        parse('żółć 🚀 @today'),
        const QuickCapture(title: 'żółć 🚀', when: TaskWhen.date(today)),
      );
    });
  });

  group('formatQuickCapture', () {
    final created = DateTime.utc(2026, 8, 20);
    Task task({TaskWhen when = TaskWhen.none, CalendarDate? deadline}) => Task(
      id: BlobRef.sha256OfBytes([1]),
      title: 'Pay rent',
      when: when,
      deadline: deadline,
      createdAt: created,
      modifiedAt: created,
    );

    test('renders the tokens the capture came from', () {
      expect(formatQuickCapture(task()), 'Pay rent');
      expect(
        formatQuickCapture(task(when: TaskWhen.someday)),
        'Pay rent @someday',
      );
      expect(
        formatQuickCapture(
          task(when: const TaskWhen.date(today)),
          today: today,
        ),
        'Pay rent @today',
      );
      expect(
        formatQuickCapture(
          task(when: const TaskWhen.date(tomorrow)),
          today: today,
        ),
        'Pay rent @tomorrow',
      );
      expect(
        formatQuickCapture(
          task(
            when: const TaskWhen.date(today),
            deadline: const CalendarDate(2026, 9, 1),
          ),
          today: today,
        ),
        'Pay rent @today !2026-09-01',
      );
    });

    test('without today, dates render as dates', () {
      expect(
        formatQuickCapture(task(when: const TaskWhen.date(today))),
        'Pay rent @2026-08-24',
      );
    });

    test('round-trips through the parser', () {
      for (final sample in [
        task(),
        task(when: TaskWhen.someday),
        task(
          when: const TaskWhen.date(tomorrow),
          deadline: const CalendarDate(2026, 9, 1),
        ),
      ]) {
        final line = formatQuickCapture(sample, today: today);
        final parsed = parseQuickCapture(line, today: today)!;
        expect(parsed.title, sample.title);
        expect(parsed.when, sample.when);
        expect(parsed.deadline, sample.deadline);
      }
    });
  });

  group('captureSections', () {
    late Directory tmp;
    late Archive archive;
    late TaskStore store;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('sai_capture_test');
      archive = await Archive.open(tmp);
      store = await TaskStore.open(archive, source: 'sai/tui');
    });

    tearDown(() async {
      store.dispose();
      await archive.close();
      tmp.deleteSync(recursive: true);
    });

    test('covers every list a capture can land in, in a fixed order', () {
      final sections = captureSections(store.projection, today);
      expect(sections.map((s) => s.name), [
        'Inbox',
        'Today',
        'Upcoming',
        'Someday',
      ]);
      expect(sections.map((s) => s.label), [
        'Inbox (0)',
        'Today (0)',
        'Upcoming (0)',
        'Someday (0)',
      ]);
      expect(sections.every((s) => s.tasks.isEmpty), isTrue);
    });

    test('every capture outcome is visible in at least one section', () async {
      for (final line in [
        'Buy oat milk',
        'Call mom @today',
        'Ring dentist @tomorrow',
        'Book flights @2026-12-01',
        'Learn the violin @someday',
      ]) {
        final id = await store.quickCapture(line, today: today);
        final task = store.projection.task(id!);
        final sections = captureSections(store.projection, today);
        expect(
          sections.any((s) => s.tasks.contains(task)),
          isTrue,
          reason: line,
        );
      }
      final byName = {
        for (final s in captureSections(store.projection, today))
          s.name: s.tasks.map((t) => t.title).toList(),
      };
      expect(byName['Inbox'], ['Buy oat milk']);
      expect(byName['Today'], ['Call mom']);
      expect(byName['Upcoming'], ['Ring dentist', 'Book flights']);
      expect(byName['Someday'], ['Learn the violin']);
    });

    test(
      'the view unions apply: a due-later Inbox task is also Upcoming',
      () async {
        await store.quickCapture('Pay rent !2026-09-01', today: today);
        final byName = {
          for (final s in captureSections(store.projection, today))
            s.name: s.tasks.map((t) => t.title).toList(),
        };
        expect(byName['Inbox'], ['Pay rent']);
        expect(byName['Upcoming'], ['Pay rent']);
      },
    );
  });
}
