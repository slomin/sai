import 'package:sai_core/sai_core.dart';
import 'package:test/test.dart';

void main() {
  const today = CalendarDate(2026, 8, 24);
  const yesterday = CalendarDate(2026, 8, 23);
  const tomorrow = CalendarDate(2026, 8, 25);
  final created = DateTime.utc(2026, 8, 20);
  final projectId = BlobRef.sha256OfBytes([9]);

  var counter = 0;
  Task task({
    TaskWhen when = TaskWhen.none,
    CalendarDate? deadline,
    bool filed = false,
    bool completed = false,
    bool cancelled = false,
    bool deleted = false,
  }) => Task(
    id: BlobRef.sha256OfBytes([++counter]),
    title: 'case $counter',
    when: when,
    deadline: deadline,
    project: filed ? projectId : null,
    createdAt: created,
    modifiedAt: created,
    completedAt: completed ? created : null,
    cancelledAt: cancelled ? created : null,
    deletedAt: deleted ? created : null,
  );

  group('listOf — the normative partition', () {
    test('the truth table', () {
      final cases = <(Task, TaskList?)>[
        // deleted wins over everything
        (task(deleted: true, when: TaskWhen.date(today)), null),
        // completed or cancelled → logbook, whatever else is set
        (task(completed: true), TaskList.logbook),
        (task(cancelled: true), TaskList.logbook),
        (
          task(completed: true, when: TaskWhen.date(tomorrow)),
          TaskList.logbook,
        ),
        (task(cancelled: true, deadline: yesterday), TaskList.logbook),
        // due (or overdue) deadline → today, even from Someday
        (task(deadline: today, filed: true), TaskList.today),
        (task(deadline: yesterday), TaskList.today),
        (task(when: TaskWhen.someday, deadline: today), TaskList.today),
        (task(when: TaskWhen.someday, deadline: yesterday), TaskList.today),
        // when-date arrived → today (an unfiled one leaves the Inbox)
        (task(when: TaskWhen.date(today)), TaskList.today),
        (task(when: TaskWhen.date(yesterday)), TaskList.today),
        (task(when: TaskWhen.date(today), filed: true), TaskList.today),
        // someday (with no due deadline) stays someday
        (task(when: TaskWhen.someday), TaskList.someday),
        (task(when: TaskWhen.someday, filed: true), TaskList.someday),
        (task(when: TaskWhen.someday, deadline: tomorrow), TaskList.someday),
        // future when-date → upcoming
        (task(when: TaskWhen.date(tomorrow)), TaskList.upcoming),
        (task(when: TaskWhen.date(tomorrow), filed: true), TaskList.upcoming),
        // no when: unfiled → inbox, filed → anytime
        (task(), TaskList.inbox),
        (task(deadline: tomorrow), TaskList.inbox),
        (task(filed: true), TaskList.anytime),
        (task(filed: true, deadline: tomorrow), TaskList.anytime),
      ];
      for (final (item, expected) in cases) {
        expect(listOf(item, today), expected, reason: item.title);
      }
    });

    test('area or heading placement counts as filed', () {
      final inArea = Task(
        id: BlobRef.sha256OfBytes([100]),
        title: 'in area',
        area: BlobRef.sha256OfBytes([101]),
        createdAt: created,
        modifiedAt: created,
      );
      expect(listOf(inArea, today), TaskList.anytime);
    });

    test('the boundary moves with today, not with the task', () {
      final item = task(when: TaskWhen.date(today));
      expect(listOf(item, yesterday), TaskList.upcoming);
      expect(listOf(item, today), TaskList.today);
      expect(listOf(item, tomorrow), TaskList.today);
    });

    test('is pure: same inputs, same answer', () {
      final item = task(when: TaskWhen.date(today), deadline: tomorrow);
      expect(listOf(item, today), listOf(item, today));
      expect(listsOf(item, today), listsOf(item, today));
    });
  });

  group('listsOf — the view unions', () {
    test('a filed Today task is also in Anytime', () {
      expect(listsOf(task(when: TaskWhen.date(today), filed: true), today), {
        TaskList.today,
        TaskList.anytime,
      });
    });

    test('an unfiled Today task is only in Today', () {
      expect(listsOf(task(when: TaskWhen.date(today)), today), {
        TaskList.today,
      });
    });

    test('a future deadline surfaces in Upcoming from Anytime or Inbox', () {
      expect(listsOf(task(filed: true, deadline: tomorrow), today), {
        TaskList.anytime,
        TaskList.upcoming,
      });
      expect(listsOf(task(deadline: tomorrow), today), {
        TaskList.inbox,
        TaskList.upcoming,
      });
    });

    test('logbook, someday and deleted stay single (or empty)', () {
      expect(listsOf(task(completed: true), today), {TaskList.logbook});
      expect(listsOf(task(when: TaskWhen.someday), today), {TaskList.someday});
      expect(listsOf(task(deleted: true), today), isEmpty);
    });
  });
}
