import 'package:nocterm/nocterm.dart';
import 'package:nocterm_riverpod/nocterm_riverpod.dart';
import 'package:riverpod/riverpod.dart';
import 'package:sai_core/sai_core.dart';

/// Quick capture and the two lists it feeds (#19). Still a placeholder
/// shell — #41 puts the real Today list and chat in.
///
/// Expects a [RiverpodScope] above it; the entry point in `bin/` provides
/// one together with [onQuit], which must end the process (nocterm's
/// `shutdownApp` calls `exit`, so nothing after `runApp` ever runs — any
/// teardown belongs in [onQuit], before that call).
///
/// Key map: the capture field is always focused, so printable keys type.
/// Ctrl+C quits (it bubbles through the field by design). **Ctrl+U** is
/// undo — not Ctrl+Z, which stays `SIGTSTP` in a real terminal
/// (`stdin.lineMode = false` clears ICANON only, ISIG stays on) and
/// would suspend the TUI mid-alt-screen.
class TuiApp extends StatefulComponent {
  const TuiApp({super.key, required this.onQuit});

  final void Function() onQuit;

  @override
  State<TuiApp> createState() => _TuiAppState();
}

class _TuiAppState extends State<TuiApp> {
  final _controller = TextEditingController();
  String _notice = '';

  @override
  void dispose() {
    _controller.dispose();
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
    return false;
  }

  void _setNotice(String notice) {
    if (!mounted) return;
    setState(() => _notice = notice);
  }

  Future<void> _capture(String line) async {
    final container = context.container;
    try {
      final store = container.read(tasksProvider.notifier).store;
      await store.quickCapture(line, today: container.read(todayProvider));
      if (!mounted) return;
      setState(() {
        _controller.clear();
        _notice = '';
      });
    } on Object catch (error) {
      _setNotice('capture failed: $error');
    }
  }

  Future<void> _undo() async {
    final container = context.container;
    try {
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
        child: Column(
          children: [
            TextField(
              controller: _controller,
              focused: true,
              placeholder:
                  'Capture to Inbox — Enter saves, '
                  '@today !2026-09-01',
              onSubmitted: _capture,
            ),
            Expanded(
              child: RiverpodConsumer<AsyncValue<TaskProjection>>(
                provider: tasksProvider,
                builder: (context, value) => switch (value) {
                  AsyncData(:final value) => _lists(context, value),
                  AsyncError(:final error) => Center(
                    child: Text('archive error: $error'),
                  ),
                  _ => Center(child: Text('opening the archive…')),
                },
              ),
            ),
            if (_notice.isNotEmpty)
              Text(_notice, style: TextStyle(color: Colors.yellow)),
            Text(
              '^C quit · ^U undo · Enter capture',
              style: TextStyle(color: Colors.gray),
            ),
          ],
        ),
      ),
    );
  }

  Component _lists(BuildContext context, TaskProjection projection) {
    final today = context.read(todayProvider);
    final inbox = projection.list(TaskList.inbox, today: today);
    final todayList = projection.list(TaskList.today, today: today);
    if (inbox.isEmpty && todayList.isEmpty) {
      return Center(child: Text(context.read(shellGreetingProvider)));
    }
    final lines = [
      'Inbox (${inbox.length})',
      for (final task in inbox) '  ${formatQuickCapture(task, today: today)}',
      'Today (${todayList.length})',
      for (final task in todayList)
        '  ${formatQuickCapture(task, today: today)}',
    ];
    return ListView(children: [for (final line in lines) Text(line)]);
  }
}
