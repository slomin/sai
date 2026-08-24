import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import 'commands.dart';

/// The quick-capture field, so tests and the chrome can find the one
/// field that captures among the shell's inputs.
const captureFieldKey = Key('capture-field');

/// The selected section's heading, the quick-capture field and the
/// section's tasks as plain rows. Placeholder rendering — #38 makes the
/// lists real.
class MainPane extends ConsumerStatefulWidget {
  const MainPane({super.key, required this.projection});

  final TaskProjection projection;

  @override
  ConsumerState<MainPane> createState() => _MainPaneState();
}

class _MainPaneState extends ConsumerState<MainPane> {
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
      notice.show('capture failed: $error');
      // Give the line back rather than losing it — unless the field has
      // moved on to a newer line meanwhile, which wins.
      if (_controller.text.isEmpty) _controller.text = line;
    } finally {
      if (mounted) focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final projection = widget.projection;
    final today = ref.watch(todayProvider);
    final section = ref.watch(selectedSectionProvider);
    final tasks = sectionTasks(projection, section, today: today);
    final title = sectionTitle(projection, section);
    final commands = AppCommands.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: captureFieldKey,
                  controller: _controller,
                  focusNode: ref.watch(captureFocusProvider),
                  autofocus: true,
                  onSubmitted: _capture,
                  decoration: const InputDecoration(
                    hintText: captureHint,
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: ref.watch(canUndoProvider) ? commands.undo : null,
                child: const Text('Undo'),
              ),
            ],
          ),
        ),
        Expanded(
          // The greeting is for an archive with nothing in it; an empty
          // section among full ones says which one it is.
          child: tasks.isEmpty
              ? Center(
                  child: Text(
                    projection.tasks.isEmpty
                        ? ref.watch(shellGreetingProvider)
                        : 'Nothing in $title',
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    for (final task in tasks)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(formatQuickCapture(task, today: today)),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
