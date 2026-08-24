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

class _Panes extends ConsumerWidget {
  const _Panes(this.projection);

  final TaskProjection projection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final showSidebar = width >= sidebarBreakpoint;
        final showChat =
            ref.watch(chatVisibleProvider) && width >= chatBreakpoint;
        return Column(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showSidebar) ...[
                    SizedBox(
                      width: sidebarWidth,
                      child: SaiSidebar(projection: projection),
                    ),
                    const VerticalDivider(width: 1, thickness: 1),
                  ],
                  Expanded(child: MainPane(projection: projection)),
                  if (showChat) ...[
                    const VerticalDivider(width: 1, thickness: 1),
                    const SizedBox(width: chatWidth, child: ChatPane()),
                  ],
                ],
              ),
            ),
            const StatusBar(),
          ],
        );
      },
    );
  }
}
