import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'chat_pane.dart';
import 'main_pane.dart';
import 'sidebar.dart';
import 'status_bar.dart';

/// Fixed widths of the side panes; the main pane takes the rest.
const sidebarWidth = 220.0;
const chatWidth = 300.0;

/// Below these window widths the side panes give way to the main pane —
/// the sidebar keeps its place longer than the chat.
const sidebarBreakpoint = 560.0;
const chatBreakpoint = 760.0;

/// Whether the window is wide enough for the sidebar.
bool sidebarFits(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= sidebarBreakpoint;

/// Whether the window is wide enough for the chat pane — the one predicate
/// the layout, the View menu and Cmd+J share, so they cannot disagree about
/// whether the chat is on screen.
bool chatFits(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= chatBreakpoint;

/// The macOS shell (#37): sidebar, main pane, chat pane, status bar.
/// Chrome and navigation only — real list rendering is #38, the chat's
/// content is #34/#39.
class SaiShell extends ConsumerWidget {
  const SaiShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: switch (ref.watch(tasksProvider)) {
        AsyncData(:final value) => _Panes(value),
        AsyncError(:final error) => Center(
          child: Text('archive error: $error'),
        ),
        // Plain text on purpose: an endless spinner animation would keep
        // widget-test pumps from ever settling.
        _ => const Center(child: Text('opening the archive…')),
      },
    );
  }
}

/// Keyed, so a pane keeps its state (typed text, focus) when a
/// breakpoint adds or removes a sibling and shifts its place in the row.
const _sidebarKey = ValueKey('sidebar');
const _mainKey = ValueKey('main');
const _chatKey = ValueKey('chat');

class _Panes extends ConsumerWidget {
  const _Panes(this.projection);

  final TaskProjection projection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showSidebar = sidebarFits(context);
    final showChat = ref.watch(chatVisibleProvider) && chatFits(context);
    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showSidebar) ...[
                SizedBox(
                  key: _sidebarKey,
                  width: sidebarWidth,
                  child: SaiSidebar(projection: projection),
                ),
                const VerticalDivider(width: 1, thickness: 1),
              ],
              Expanded(
                key: _mainKey,
                child: MainPane(projection: projection),
              ),
              if (showChat) ...[
                const VerticalDivider(width: 1, thickness: 1),
                const SizedBox(
                  key: _chatKey,
                  width: chatWidth,
                  child: ChatPane(),
                ),
              ],
            ],
          ),
        ),
        const StatusBar(),
      ],
    );
  }
}
