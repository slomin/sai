import 'dart:async';

import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'chat_pane.dart';

final _listStateProvider = Provider(
  (ref) => (tasks: ref.watch(tasksProvider), today: ref.watch(todayProvider)),
);

final _chatViewProvider = Provider(
  (ref) => (
    chat: ref.watch(chatProvider),
    reasoningOn: ref.watch(reasoningProvider),
  ),
);

/// Quick capture, the lists it feeds (#19) and the chat (#34). Still a
/// thin shell — #41 puts the real Today list in.
///
/// Expects a [RiverpodScope] above it; the entry point in `bin/` provides
/// one together with [onQuit], which must end the process (nocterm's
/// `shutdownApp` calls `exit`, so nothing after `runApp` ever runs — any
/// teardown belongs in [onQuit], before that call).
///
/// Key map: one of the two fields is always focused, so printable keys
/// type; Tab moves between them. Ctrl+C quits (it bubbles through the
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

enum _Pane { capture, chat }

class _TuiAppState extends State<TuiApp> {
  final _controller = TextEditingController();
  final _chatInput = TextEditingController();
  final _chatScroll = AutoScrollController();
  var _pane = _Pane.capture;
  String _notice = '';

  @override
  void dispose() {
    _controller.dispose();
    _chatInput.dispose();
    _chatScroll.dispose();
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
    if (event.logicalKey == LogicalKey.tab) {
      setState(() {
        _pane = _pane == _Pane.capture ? _Pane.chat : _Pane.capture;
      });
      return true;
    }
    if (event.logicalKey == LogicalKey.escape) {
      context.container.read(chatProvider.notifier).cancel();
      return true;
    }
    return false;
  }

  void _ask(String line) {
    if (line.trim().isEmpty) return;
    final chat = context.container.read(chatProvider.notifier);
    // A refusal is set before the first await; only an accepted line
    // clears the field, so nothing typed is lost.
    unawaited(chat.send(line));
    if (context.container.read(chatProvider).error == null) {
      setState(_chatInput.clear);
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
                if (_notice.isNotEmpty)
                  Text(_notice, style: TextStyle(color: Colors.yellow)),
                // One row, whatever the provider is called: a wrapped
                // status would take its extra rows from the list above.
                RiverpodConsumer<String>(
                  provider: llmStatusProvider,
                  builder: (context, status) => Text(
                    status,
                    style: TextStyle(color: Colors.gray),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '^C quit · ^U undo · Tab chat · Esc stop',
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
    final sections = captureSections(projection, today);
    if (sections.every((section) => section.tasks.isEmpty)) {
      return Center(child: Text(context.read(shellGreetingProvider)));
    }
    final lines = [
      for (final section in sections) ...[
        section.label,
        for (final task in section.tasks)
          '  ${formatQuickCapture(task, today: today)}',
      ],
    ];
    return ListView(children: [for (final line in lines) Text(line)]);
  }
}
