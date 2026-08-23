import 'package:nocterm/nocterm.dart';

class ChatMessage {
  ChatMessage(this.role, this.text);
  final String role; // 'you' | 'sai'
  String text;
}

/// Right pane: scrollback of messages (the last one may still be
/// streaming) plus a multi-line input at the bottom.
class ChatPane extends StatelessComponent {
  const ChatPane({
    super.key,
    required this.messages,
    required this.streaming,
    required this.focused,
    required this.scrollController,
    required this.inputController,
    required this.onSubmit,
  });

  final List<ChatMessage> messages;
  final bool streaming;
  final bool focused;
  final AutoScrollController scrollController;
  final TextEditingController inputController;
  final void Function(String) onSubmit;

  @override
  Component build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: BoxBorder.all(color: Colors.gray),
            ),
            child: ListView.builder(
              controller: scrollController,
              padding: EdgeInsets.symmetric(horizontal: 1),
              itemCount: messages.length,
              itemBuilder: (context, index) {
                final m = messages[index];
                final isLast = index == messages.length - 1;
                final cursor =
                    streaming && isLast && m.role == 'sai' ? '▌' : '';
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.role == 'you' ? 'you' : 'sai',
                      style: TextStyle(
                        color: m.role == 'you' ? Colors.green : Colors.magenta,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text('${m.text}$cursor'),
                    Text(''),
                  ],
                );
              },
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            border: BoxBorder.all(
              color: focused ? Colors.cyan : Colors.gray,
            ),
          ),
          child: TextField(
            controller: inputController,
            focused: focused,
            maxLines: 4,
            minLines: 1,
            placeholder: 'Ask sai… (Enter sends, Ctrl+J newline)',
            onSubmitted: onSubmit,
          ),
        ),
      ],
    );
  }
}
