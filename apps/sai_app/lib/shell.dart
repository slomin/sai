import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'assistant/assistant_band.dart';
import 'inspector/task_inspector.dart';
import 'sidebar.dart';
import 'theme/motion.dart';
import 'theme/sai_theme.dart';
import 'theme/sai_tokens.dart';
import 'top_bar.dart';
import 'workspace/task_list_pane.dart';

/// The sidebar's fixed width; the main column takes the rest.
const sidebarWidth = 264.0;

/// Below this window width the sidebar gives way to the list.
const sidebarBreakpoint = 640.0;

/// Whether the window is wide enough for the sidebar.
bool sidebarFits(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= sidebarBreakpoint;

/// The macOS shell (#37, #72, #74): the top bar, the sidebar, and the
/// main column — the list, the inspector beside it while a task is
/// selected, and the assistant's ink band docked under both.
class SaiShell extends ConsumerWidget {
  const SaiShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = context.saiText;
    return Scaffold(
      body: switch (ref.watch(tasksProvider)) {
        AsyncData(:final value) => _Workspace(value),
        AsyncError(:final error) => Center(
          child: Text('archive error: $error', style: text.bodyDim),
        ),
        // Plain text on purpose: an endless spinner animation would keep
        // widget-test pumps from ever settling.
        _ => Center(child: Text('opening the archive…', style: text.bodyDim)),
      },
    );
  }
}

/// Keyed, so the list keeps its state (typed text, focus, selection)
/// when the sidebar comes and goes at its breakpoint.
const _mainKey = ValueKey('main');

class _Workspace extends ConsumerWidget {
  const _Workspace(this.projection);

  final TaskProjection projection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showSidebar = sidebarFits(context);
    final selected = ref.watch(selectedTaskProvider);
    final hasTask = selected != null && projection.task(selected) != null;
    return Column(
      children: [
        TopBar(projection: projection),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showSidebar) ...[
                const SizedBox(width: sidebarWidth, child: SaiSidebar()),
                const VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: SaiColors.rule,
                ),
              ],
              Expanded(
                key: _mainKey,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = inspectorWidth(constraints.maxWidth);
                    final open = hasTask && width != null;
                    Widget pane(bool open) => open
                        ? SizedBox(
                            width: width,
                            height: double.infinity,
                            child: TaskInspector(projection: projection),
                          )
                        : const SizedBox(height: double.infinity);
                    return Column(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(
                                child: TaskListPane(projection: projection),
                              ),
                              // Like the band: under Reduce Motion the
                              // pane just is; otherwise it slides open.
                              if (SaiMotion.reduced(context))
                                pane(open)
                              else
                                AnimatedSize(
                                  duration: SaiDurations.band,
                                  curve: Curves.easeOutCubic,
                                  alignment: Alignment.centerRight,
                                  child: pane(open),
                                ),
                            ],
                          ),
                        ),
                        AssistantBand(
                          bodyHeight: assistantBandHeight(
                            constraints.maxHeight,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
