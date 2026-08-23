import 'dart:async';

import 'package:nocterm/nocterm.dart';

import 'chat_pane.dart';
import 'fake_stream.dart';
import 'task_list.dart';

enum Pane { list, chat }

/// Two panes side by side. Tab toggles focus; the list takes vim keys
/// (j/k/g/G) and arrows; the chat takes text. Every streamed token
/// rebuilds the whole tree on purpose — that is the flicker test.
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
      listScroll.ensureVisible(itemOffset: selected.toDouble(), itemExtent: 1);
    });
  }

  bool _onKey(KeyboardEvent e) {
    if (e.logicalKey == LogicalKey.keyC && e.isControlPressed) {
      shutdownApp();
      return true;
    }
    if (e.logicalKey == LogicalKey.tab) {
      setState(() => focus = focus == Pane.list ? Pane.chat : Pane.list);
      return true;
    }
    if (focus != Pane.list) return false;

    switch (e.logicalKey) {
      case LogicalKey.keyJ || LogicalKey.arrowDown:
        _select(selected + 1);
      case LogicalKey.keyK || LogicalKey.arrowUp:
        _select(selected - 1);
      case LogicalKey.keyG when e.isShiftPressed:
        _select(tasks.length - 1);
      case LogicalKey.keyG:
        _select(0);
      case LogicalKey.keyQ:
        shutdownApp();
      case LogicalKey.enter:
        _send('What should I do about "${tasks[selected].trim()}"?');
      default:
        return false;
    }
    return true;
  }

  void _send(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || streaming) return;
    input.clear();
    final reply = ChatMessage('sai', '');
    setState(() {
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
      onDone: () {
        if (!mounted) return;
        setState(() => _stream = null);
      },
    );
  }

  @override
  Component build(BuildContext context) {
    return Focusable(
      focused: true,
      onKeyEvent: _onKey,
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: TaskList(
                    tasks: tasks,
                    selected: selected,
                    focused: focus == Pane.list,
                    controller: listScroll,
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: ChatPane(
                    messages: messages,
                    streaming: streaming,
                    focused: focus == Pane.chat,
                    scrollController: chatScroll,
                    inputController: input,
                    onSubmit: _send,
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
              '${streaming ? ' · streaming' : ''}',
              style: TextStyle(color: Colors.gray),
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}
