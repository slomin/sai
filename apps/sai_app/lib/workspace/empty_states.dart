import 'package:sai_core/sai_core.dart';

/// What an empty list says (the reference supplies Inbox, Today and
/// Logbook; the rest is written in the same voice).
final class EmptyCopy {
  const EmptyCopy(this.eyebrow, this.title, this.body);

  final String eyebrow;
  final String title;
  final String body;
}

EmptyCopy emptyCopy(SidebarSection section, String title) => switch (section) {
  ListSection(list: TaskList.inbox) => const EmptyCopy(
    'Inbox',
    'Inbox is clear.',
    'Half-thoughts land here first. Press ⌘N and type one line — filing '
        'can wait.',
  ),
  ListSection(list: TaskList.today) => const EmptyCopy(
    'Today',
    'Nothing planned for today.',
    'Pull something in from Upcoming, or ask sai for a shape for the day.',
  ),
  ListSection(list: TaskList.logbook) => const EmptyCopy(
    'Logbook',
    'Nothing finished yet.',
    'Everything you complete or cancel collects here the moment it '
        'happens, newest day first. Check a row to reopen it. Nothing is '
        'ever removed.',
  ),
  ListSection(list: TaskList.upcoming) => const EmptyCopy(
    'Upcoming',
    'Nothing scheduled.',
    'Give a task a day — @tomorrow, or @2026-09-04 — and it waits here '
        'until then.',
  ),
  ListSection(list: TaskList.anytime) => const EmptyCopy(
    'Anytime',
    'Nothing filed for anytime.',
    'Tasks in an area or a project that have no day yet live here.',
  ),
  ListSection(list: TaskList.someday) => const EmptyCopy(
    'Someday',
    'Nothing on the long list.',
    'Mark a task @someday to park it here — out of the way, not '
        'forgotten.',
  ),
  TrashSection() => const EmptyCopy(
    'Trash',
    'Trash is empty.',
    'Deleted tasks wait here, exactly as they were. Select one and '
        'choose Restore to bring it back. Nothing is ever removed from '
        'the archive.',
  ),
  AreaSection() || ProjectSection() => EmptyCopy(
    title,
    'Nothing here yet.',
    'Capture a task and file it into $title.',
  ),
  TagSection() => EmptyCopy(
    title,
    'Nothing tagged $title.',
    'Tag a task and it collects here — tags cut across lists and projects.',
  ),
};
