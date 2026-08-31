import 'dart:async';

import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'chat_pane.dart';
import 'suggestion_lane.dart';
import 'task_list.dart';

final _listStateProvider = Provider(
  (ref) => (tasks: ref.watch(tasksProvider), today: ref.watch(todayProvider)),
);

final _chatViewProvider = Provider(
  (ref) => (
    chat: ref.watch(chatProvider),
    reasoningOn: ref.watch(reasoningProvider),
    views: ref.watch(suggestionViewsProvider),
    note: ref.watch(proposalsProvider.select((s) => s.current?.note ?? '')),
  ),
);

/// Quick capture, the lists it feeds (#19, selectable since #41) and the
/// chat (#34).
///
/// Expects a [RiverpodScope] above it; the entry point in `bin/` provides
/// one together with [onQuit], which must end the process (nocterm's
/// `shutdownApp` calls `exit`, so nothing after `runApp` ever runs — any
/// teardown belongs in [onQuit], before that call).
///
/// Key map: one of the two fields is always focused, so printable keys
/// type; Tab moves to the chat, Esc back to capture (or stops a running
/// answer first). With capture focused, ↑/↓ move the cursor over the
/// task rows (a single-line field lets them through) and **Ctrl+D**
/// completes the selected task; neither does anything in the chat. Ctrl+C quits (it bubbles through the
/// field by design). **Ctrl+U** is undo — not Ctrl+Z, which stays
/// `SIGTSTP` in a real terminal (`stdin.lineMode = false` clears ICANON
/// only, ISIG stays on) and would suspend the TUI mid-alt-screen. Esc
/// stops the assistant's answer.
class TuiApp extends StatefulComponent {
  const TuiApp({super.key, required this.onQuit});

  final void Function() onQuit;

  @override
  State<TuiApp> createState() => _TuiAppState();
}

enum _Pane { capture, chat, lane }

class _TuiAppState extends State<TuiApp> {
  final _controller = TextEditingController();
  final _chatInput = TextEditingController();
  final _chatScroll = AutoScrollController();
  final _listScroll = ScrollController();
  var _pane = _Pane.capture;

  /// The lane's cursor (#35); clamped against the shown suggestions
  /// whenever it is used.
  var _laneCursor = 0;

  /// The cursor over the task rows; clamped against the current list
  /// whenever it is read, so it never points past a shrunken list.
  var _selected = 0;

  /// The archive head count this process last replayed to. The log is
  /// shared with the app (one store per process, ADR 0004 amendment):
  /// a count that moved means another writer appended, and a reload
  /// brings its events in. Own commits move it too and cost one spare
  /// replay — microseconds per line, not worth tracking apart.
  int? _replayedCount;
  Timer? _poll;

  /// How often the head is checked. A read of one tiny file.
  static const pollEvery = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(pollEvery, (_) => _followArchive());
  }

  String _notice = '';

  @override
  void dispose() {
    _controller.dispose();
    _chatInput.dispose();
    _chatScroll.dispose();
    _listScroll.dispose();
    _poll?.cancel();
    super.dispose();
  }

  bool _onKey(KeyboardEvent event) {
    if (event.logicalKey == LogicalKey.keyC && event.isControlPressed) {
      component.onQuit();
      return true;
    }
    if (event.logicalKey == LogicalKey.keyU && event.isControlPressed) {
      _undo();
      return true;
    }
    // List keys belong to the capture pane: in the chat, Ctrl+D while
    // typing to the assistant must not touch a task.
    if (_pane == _Pane.capture &&
        event.logicalKey == LogicalKey.keyD &&
        event.isControlPressed) {
      _complete();
      return true;
    }
    if (_pane == _Pane.capture &&
        (event.logicalKey == LogicalKey.arrowUp ||
            event.logicalKey == LogicalKey.arrowDown)) {
      _move(event.logicalKey == LogicalKey.arrowDown ? 1 : -1);
      return true;
    }
    // The proposal trigger (#35): the chat draft — or, empty, the
    // default request — as a schema-constrained turn. Anywhere: a
    // control chord carries no character, so no field swallows it.
    if (event.logicalKey == LogicalKey.keyP && event.isControlPressed) {
      _propose(_chatInput.text);
      return true;
    }
    // The lane's own keys (#35): plain letters are safe here — no
    // field is focused while the lane is.
    if (_pane == _Pane.lane) {
      final views = context.container.read(suggestionViewsProvider);
      final max = views.length - 1;
      if (views.isEmpty) {
        setState(() => _pane = _Pane.chat);
      } else if (event.logicalKey == LogicalKey.arrowUp ||
          event.logicalKey == LogicalKey.arrowDown) {
        final step = event.logicalKey == LogicalKey.arrowDown ? 1 : -1;
        setState(() => _laneCursor = (_laneCursor + step).clamp(0, max));
        return true;
      } else if (event.logicalKey == LogicalKey.keyY ||
          event.logicalKey == LogicalKey.enter) {
        unawaited(_verdict(_laneCursor.clamp(0, max), accept: true));
        return true;
      } else if (event.logicalKey == LogicalKey.keyN) {
        unawaited(_verdict(_laneCursor.clamp(0, max), accept: false));
        return true;
      }
    }
    // Directional, not toggles: a real terminal can deliver a key twice
    // (see tool/smoke/tui.py), and a toggle fired twice goes nowhere.
    if (event.logicalKey == LogicalKey.tab) {
      if (_pane == _Pane.capture) {
        setState(() => _pane = _Pane.chat);
      } else if (_pane == _Pane.chat &&
          context.container.read(suggestionViewsProvider).isNotEmpty) {
        setState(() {
          _pane = _Pane.lane;
          _laneCursor = 0;
        });
      }
      return true;
    }
    if (event.logicalKey == LogicalKey.escape) {
      final chat = context.container.read(chatProvider);
      if (chat.busy) {
        context.container.read(chatProvider.notifier).cancel();
      } else if (_pane == _Pane.lane) {
        setState(() => _pane = _Pane.chat);
      } else if (_pane != _Pane.capture) {
        setState(() => _pane = _Pane.capture);
      }
      return true;
    }
    return false;
  }

  /// Sends [line] — or, blank, the default request — as a proposal
  /// turn; the lane shows what comes back. Mirrors [_ask]'s
  /// draft-keeping.
  void _propose(String line) {
    final chat = context.container.read(chatProvider.notifier);
    final sending = chat.propose(line);
    if (context.container.read(chatProvider).error != null) return;
    setState(_chatInput.clear);
    unawaited(
      sending.then((sent) {
        if (!mounted) return;
        if (!sent && _chatInput.text.isEmpty) {
          setState(() => _chatInput.text = line);
        }
      }),
    );
  }

  /// The lane's verdict on one suggestion; a refusal lands on the
  /// notice line.
  Future<void> _verdict(int index, {required bool accept}) async {
    final proposals = context.container.read(proposalsProvider.notifier);
    final refusal = accept
        ? await proposals.accept(index)
        : await proposals.reject(index);
    _setNotice(refusal ?? '');
  }

  void _ask(String line) {
    if (line.trim().isEmpty) return;
    final chat = context.container.read(chatProvider.notifier);
    // A refusal before the first await keeps the line where it is; one
    // after it (the archive would not take the message) gives it back,
    // unless something newer has been typed meanwhile.
    final sending = chat.send(line);
    if (context.container.read(chatProvider).error != null) return;
    setState(_chatInput.clear);
    unawaited(
      sending.then((sent) {
        if (!sent && mounted && _chatInput.text.isEmpty) {
          setState(() => _chatInput.text = line);
        }
      }),
    );
  }

  /// The capture sections of the settled projection, or null before it.
  List<CaptureSection>? _sections() {
    final container = context.container;
    final projection = container.read(tasksProvider).value;
    if (projection == null) return null;
    return captureSections(
      projection,
      container.read(todayProvider),
      visibility: container.read(finishedTaskVisibilityProvider),
    );
  }

  void _move(int by) {
    final sections = _sections();
    if (sections == null) return;
    final rows = TaskListPane.rows(sections);
    // Start from where the marker is, not where it was: a shrunken list
    // may have clamped the rendered selection below the stored index.
    final current = TaskListPane.clamp(_selected, rows.length);
    if (current < 0) return;
    final next = TaskListPane.clamp(current + by, rows.length);
    setState(() {
      _selected = next;
      _listScroll.ensureIndexVisible(
        index: TaskListPane.screenRow(sections, next),
      );
    });
  }

  Future<void> _complete() async {
    final sections = _sections();
    final rows = sections == null
        ? const <Task>[]
        : TaskListPane.rows(sections);
    final index = TaskListPane.clamp(_selected, rows.length);
    if (index < 0) {
      _setNotice('nothing selected');
      return;
    }
    final task = rows[index];
    final store = context.container.read(tasksProvider.notifier).store;
    // A row kept in its list after finishing (#97) reopens on the same
    // key, as the check does in the app.
    final reopen = task.status != TaskStatus.open;
    try {
      if (reopen) {
        await store.reopenTask(task.id);
        _setNotice('reopened: ${task.title}');
      } else {
        await store.completeTask(task.id);
        _setNotice('done: ${task.title}');
      }
    } on Object catch (error) {
      _setNotice('${reopen ? 'reopen' : 'complete'} failed: $error');
    }
  }

  Future<void> _followArchive() async {
    final container = context.container;
    try {
      if (container.read(tasksProvider).value == null) return;
      final archive = await container.read(archiveProvider.future);
      final count = (await archive.head()).count;
      if (count == _replayedCount) return;
      await container.read(tasksProvider.notifier).reload();
      _replayedCount = count;
    } on StateError catch (error) {
      // The container is gone (riverpod's own wording): the tester never
      // unmounts, so the timer would otherwise outlive it and fail a
      // later test. Ending the poll is right in a real run as well.
      if (error.message.contains('disposed')) {
        _poll?.cancel();
        return;
      }
      _setNotice('reload failed: $error');
    } on Object catch (error) {
      _setNotice('reload failed: $error');
    }
  }

  void _setNotice(String notice) {
    if (!mounted) return;
    setState(() => _notice = notice);
  }

  Future<void> _capture(String line) async {
    // Clear before the append settles: a key-repeated Enter resubmits an
    // empty line, which captures nothing, instead of the same line twice.
    setState(_controller.clear);
    final container = context.container;
    try {
      // The field renders before the store settles; an early Enter waits
      // for it instead of failing on the not-yet-open store.
      await container.read(tasksProvider.future);
      final store = container.read(tasksProvider.notifier).store;
      await store.quickCapture(line, today: container.read(todayProvider));
      if (!mounted) return;
      setState(() => _notice = '');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        // Give the line back rather than losing it.
        _controller.text = line;
        _notice = 'capture failed: $error';
      });
    }
  }

  Future<void> _undo() async {
    final container = context.container;
    try {
      await container.read(tasksProvider.future);
      if (!container.read(canUndoProvider)) {
        _setNotice('nothing to undo');
        return;
      }
      await container.read(tasksProvider.notifier).store.undo();
      _setNotice('');
    } on Object catch (error) {
      _setNotice('undo failed: $error');
    }
  }

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: _onKey,
      child: Container(
        decoration: BoxDecoration(border: BoxBorder.all(color: Colors.gray)),
        child: RiverpodConsumer(
          provider: _chatViewProvider,
          builder: (context, view) {
            final chat = view.chat;
            final chatFocused = _pane == _Pane.chat;
            final pane = ChatPane(
              state: chat,
              reasoningOn: view.reasoningOn,
              focused: chatFocused,
              scroll: _chatScroll,
              input: _chatInput,
              onSubmit: _ask,
            );
            return Column(
              children: [
                TextField(
                  controller: _controller,
                  focused: _pane == _Pane.capture,
                  placeholder: captureHint,
                  onSubmitted: _capture,
                ),
                Expanded(
                  child: RiverpodConsumer(
                    provider: _listStateProvider,
                    builder: (context, state) => switch (state.tasks) {
                      AsyncData(:final value) => _lists(value, state.today),
                      AsyncError(:final error) => Center(
                        child: Text('archive error: $error'),
                      ),
                      _ => Center(child: Text('opening the archive…')),
                    },
                  ),
                ),
                // The chat takes rows only once it is in use.
                if (ChatPane.open(chat, focused: chatFocused))
                  Expanded(child: pane)
                else
                  pane,
                // The lane (#35): the latest proposal, while there is
                // one; at most a header and eight rows.
                if (view.views.isNotEmpty)
                  SuggestionLaneTui(
                    views: view.views,
                    note: view.note,
                    cursor: _laneCursor,
                    focused: _pane == _Pane.lane,
                  ),
                if (_notice.isNotEmpty)
                  Text(_notice, style: TextStyle(color: Colors.yellow)),
                // One row, whatever the provider is called: a wrapped
                // status would take its extra rows from the list above.
                // Watching the warmer also keeps it alive for the
                // interactive client's life (#105); the CLI never does.
                RiverpodConsumer<WarmState>(
                  provider: cacheWarmerProvider,
                  builder: (context, warm) => RiverpodConsumer<String>(
                    provider: llmStatusProvider,
                    builder: (context, status) => Text(
                      warm.phase == WarmPhase.warming
                          ? '$status · ${warmingWord(warm.fraction)}'
                          : status,
                      style: TextStyle(color: Colors.gray),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                Text(
                  '^C quit · ^U undo · ^D done · ↑↓ select · Tab chat/lane '
                  '· ^P propose · y/n · Esc back',
                  style: TextStyle(color: Colors.gray),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Component _lists(TaskProjection projection, CalendarDate today) {
    final sections = captureSections(
      projection,
      today,
      visibility: context.read(finishedTaskVisibilityProvider),
    );
    if (sections.every((section) => section.tasks.isEmpty)) {
      return Center(child: Text(context.read(shellGreetingProvider)));
    }
    return TaskListPane(
      sections: sections,
      today: today,
      selected: TaskListPane.clamp(
        _selected,
        TaskListPane.rows(sections).length,
      ),
      scroll: _listScroll,
    );
  }
}
