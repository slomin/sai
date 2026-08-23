import 'dart:async';

import 'package:nocterm/nocterm.dart';

import 'chat_pane.dart';
import 'fake_stream.dart';
import 'task_list.dart';

enum Pane { list, chat }

/// Two panes side by side, each under its own [Focusable]. Tab toggles
/// focus; the list takes vim keys (j/k/g/G) and arrows; the chat takes
/// text. Every streamed token rebuilds the whole tree on purpose — that
/// is the flicker test.
class SpikeApp extends StatefulComponent {
  const SpikeApp({
    super.key,
    this.reply = cannedReply,
    this.tokenGap = const Duration(milliseconds: 25),
  });

  final String reply;
  final Duration tokenGap;

  @override
  State<SpikeApp> createState() => _SpikeAppState();
}

class _SpikeAppState extends State<SpikeApp> {
  final tasks = fakeTasks();
  final listScroll = ScrollController();
  final chatScroll = AutoScrollController();
  final input = TextEditingController();
  final messages = <ChatMessage>[];

  Pane focus = Pane.list;
  int selected = 0;
  StreamSubscription<String>? _stream;
  int tokens = 0;
  String notice = '';

  bool get streaming => _stream != null;

  @override
  void dispose() {
    _stream?.cancel();
    listScroll.dispose();
    chatScroll.dispose();
    input.dispose();
    super.dispose();
  }

  void _select(int index) {
    setState(() {
      selected = index.clamp(0, tasks.length - 1);
      listScroll.ensureIndexVisible(index: selected);
    });
  }

  /// Keys both panes answer to. Everything else bubbles to the pane.
  bool _onGlobalKey(KeyboardEvent e) {
    if (e.logicalKey == LogicalKey.keyC && e.isControlPressed) {
      shutdownApp();
      return true;
    }
    if (e.logicalKey == LogicalKey.tab) {
      setState(() => focus = focus == Pane.list ? Pane.chat : Pane.list);
      return true;
    }
    return false;
  }

  bool _onListKey(KeyboardEvent e) {
    if (_onGlobalKey(e)) return true;
    final plain = !e.isControlPressed && !e.isAltPressed && !e.isMetaPressed;
    switch (e.logicalKey) {
      case LogicalKey.keyJ when plain && !e.isShiftPressed:
      case LogicalKey.arrowDown:
        _select(selected + 1);
      case LogicalKey.keyK when plain && !e.isShiftPressed:
      case LogicalKey.arrowUp:
        _select(selected - 1);
      case LogicalKey.keyG when plain && e.isShiftPressed:
        _select(tasks.length - 1);
      case LogicalKey.keyG when plain:
        _select(0);
      case LogicalKey.keyQ when plain && !e.isShiftPressed:
        shutdownApp();
      case LogicalKey.enter:
        _send('What should I do about "${tasks[selected]}"?');
      default:
        return false;
    }
    return true;
  }

  /// Returns true when the message was accepted and a reply started.
  bool _send(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    if (streaming) {
      setState(() => notice = 'busy');
      return false;
    }
    final reply = ChatMessage('sai', '');
    setState(() {
      notice = '';
      messages.add(ChatMessage('you', trimmed));
      messages.add(reply);
    });
    _stream = fakeTokens(component.reply, gap: component.tokenGap).listen(
      (token) {
        if (!mounted) return;
        setState(() {
          reply.text += token;
          tokens++;
        });
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          reply.text += ' [stream error: $error]';
          _stream = null;
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _stream = null);
      },
    );
    return true;
  }

  @override
  Component build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 2,
                child: Focusable(
                  focused: focus == Pane.list,
                  onKeyEvent: _onListKey,
                  child: TaskList(
                    tasks: tasks,
                    selected: selected,
                    focused: focus == Pane.list,
                    controller: listScroll,
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: Focusable(
                  focused: focus == Pane.chat,
                  onKeyEvent: _onGlobalKey,
                  child: ChatPane(
                    messages: messages,
                    streaming: streaming,
                    focused: focus == Pane.chat,
                    scrollController: chatScroll,
                    inputController: input,
                    onSubmit: (text) {
                      if (_send(text)) input.clear();
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: EdgeInsets.symmetric(horizontal: 1),
          child: Text(
            'Tab switch pane · j/k/g/G move · Enter ask · q quit'
            ' · focus:${focus.name} · tokens:$tokens'
            '${streaming ? ' · streaming' : ''}'
            '${notice.isEmpty ? '' : ' · $notice'}',
            style: TextStyle(color: Colors.gray),
            maxLines: 1,
          ),
        ),
      ],
    );
  }
}
