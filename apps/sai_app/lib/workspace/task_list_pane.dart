import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../commands.dart';
import '../organise/organise_commands.dart';
import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import '../widgets/eyebrow.dart';
import '../widgets/sai_dialog.dart';
import 'task_commands.dart';
import 'dates.dart';
import 'task_list.dart';

/// The quick-capture field, so tests and the chrome can find the one
/// field that captures among the shell's inputs.
const captureFieldKey = Key('capture-field');

/// The selected section's title, so tests can read which list is shown.
const paneTitleKey = Key('pane-title');

/// A project view's "+ heading", for tests.
const addHeadingKey = Key('add-heading');

/// The selected section (#72): the day's eyebrow, the title and its count,
/// the capture field, then the rows from [taskViewProvider] — or the
/// list's empty state.
class TaskListPane extends ConsumerStatefulWidget {
  const TaskListPane({super.key, required this.projection});

  final TaskProjection projection;

  @override
  ConsumerState<TaskListPane> createState() => _TaskListPaneState();
}

/// `+ HEADING` in a project's meta line: a new heading at the end of the
/// project (#74).
class _AddHeading extends ConsumerWidget {
  const _AddHeading({required this.project, required this.title});

  final ProjectId project;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Semantics(
      button: true,
      label: 'New heading',
      child: ExcludeSemantics(
        child: InkWell(
          key: addHeadingKey,
          onTap: () async {
            final name = await promptForTitle(
              context,
              eyebrow: title,
              title: 'New heading',
              confirm: 'Create',
            );
            if (name == null) return;
            await ref
                .read(organiseCommandsProvider)
                .createHeading(project, name);
          },
          child: Text('+ HEADING', style: context.saiText.eyebrow),
        ),
      ),
    );
  }
}

class _TaskListPaneState extends ConsumerState<TaskListPane> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _capture(String line) async {
    // Clear before the append settles: a key-repeated Enter resubmits an
    // empty line, which captures nothing, instead of the same line twice.
    _controller.clear();
    final notice = ref.read(noticeProvider.notifier);
    final focus = ref.read(captureFocusProvider);
    try {
      final store = ref.read(tasksProvider.notifier).store;
      await store.quickCapture(line, today: ref.read(todayProvider));
      if (!mounted) return;
      notice.clear();
    } on Object catch (error) {
      if (!mounted) return;
      notice.show('capture failed: ${describeFailure(error)}');
      // Give the line back rather than losing it — unless the field has
      // moved on to a newer line meanwhile, which wins.
      if (_controller.text.isEmpty) _controller.text = line;
    } finally {
      if (mounted) focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final today = ref.watch(todayProvider);
    final section = ref.watch(selectedSectionProvider);
    final view = ref.watch(taskViewProvider(section));
    // The selection follows the task (#74): it stays while the task is
    // merely edited out of this list (the inspector is still on it), and
    // goes when the task is gone — deleted outside the Trash, or unknown
    // — or when the person moves to another section that does not show
    // it. Effects, so they live in listen, not build.
    ref.listen(tasksProvider, (_, next) {
      final selected = ref.read(selectedTaskProvider);
      final projection = next.value;
      if (selected == null || projection == null) return;
      final task = projection.task(selected);
      final trash = ref.read(selectedSectionProvider) == const TrashSection();
      if (task == null || (task.deletedAt != null && !trash)) {
        ref.read(selectedTaskProvider.notifier).clear();
      }
    });
    ref.listen(selectedSectionProvider, (_, next) {
      final selected = ref.read(selectedTaskProvider);
      if (selected == null) return;
      final tasks = ref.read(taskViewProvider(next)).value?.tasks;
      if (tasks != null && !tasks.any((t) => t.id == selected)) {
        ref.read(selectedTaskProvider.notifier).clear();
      }
    });
    final text = context.saiText;
    final title = view.value?.title ?? sectionTitle(widget.projection, section);
    final tasks = view.value?.tasks ?? const <Task>[];
    final withDeadline = tasks.where((t) => t.deadline != null).length;
    final meta = tasks.isEmpty
        ? null
        : '${tasks.length == 1 ? '1 TASK' : '${tasks.length} TASKS'}'
              '${section == const ListSection(TaskList.today) ? ' · $withDeadline WITH DEADLINES' : ''}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Eyebrow(longDay(today)),
              const SizedBox(height: 6),
              Text(
                title,
                key: paneTitleKey,
                style: text.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 14,
                child: Row(
                  children: [
                    if (meta != null) Eyebrow(meta, dim: true),
                    // An archived project refuses new members; no offer.
                    if (section case ProjectSection(:final project)
                        when widget.projection.projects[project]?.archivedAt ==
                            null) ...[
                      if (meta != null) const SizedBox(width: 12),
                      _AddHeading(project: project, title: title),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 14, 28, 10),
          // Esc leaves the field (#89): focus falls back to the chrome's
          // resting scope, where the arrow keys are live again.
          child: CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  ref.read(captureFocusProvider).unfocus(),
            },
            child: TextField(
              key: captureFieldKey,
              controller: _controller,
              // No autofocus (#76): focus rests on the chrome, so typing
              // opens Quick Find and ⌘N is what brings it here.
              focusNode: ref.watch(captureFocusProvider),
              onSubmitted: _capture,
              style: text.body,
              decoration: InputDecoration(
                hintText: captureHint,
                prefixIcon: const Padding(
                  padding: EdgeInsets.only(left: 14, right: 8),
                  child: Text(
                    '+',
                    style: TextStyle(
                      color: SaiColors.red,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                prefixIconConstraints: const BoxConstraints(minWidth: 0),
              ),
            ),
          ),
        ),
        Expanded(
          // The body shows the empty state itself, so a row finishing as
          // the last one keeps its place through the confirmation.
          child: switch (view) {
            AsyncData(:final value) => TaskListBody(
              view: value,
              projection: widget.projection,
              today: today,
            ),
            AsyncError(:final error) => Center(
              child: Text('archive error: $error', style: text.bodyDim),
            ),
            _ => const SizedBox.shrink(),
          },
        ),
      ],
    );
  }
}
