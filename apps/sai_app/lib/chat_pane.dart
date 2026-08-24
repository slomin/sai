import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'commands.dart';

/// The chat pane's input, so tests and Cmd+J can find it.
const chatFieldKey = Key('chat-field');

/// The collapsible pane the assistant will live in. Chrome only: the
/// conversation itself is #34 and its rendering #39, so for now the
/// input owns up to doing nothing.
class ChatPane extends ConsumerWidget {
  const ChatPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'The assistant will answer here once a provider is set up.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            key: chatFieldKey,
            focusNode: ref.watch(chatFocusProvider),
            onSubmitted: (_) => ref
                .read(noticeProvider.notifier)
                .show('chat is not wired up yet'),
            decoration: const InputDecoration(
              hintText: 'Ask sai…',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
      ],
    );
  }
}
