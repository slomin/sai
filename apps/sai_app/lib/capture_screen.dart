import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

/// Quick capture and the two lists it feeds (#19). Deliberately
/// throwaway: #37 lays out the real shell, #20 the real list views.
///
/// While the capture field is focused, Cmd+Z undoes the last *task*
/// mutation, not the last typed character — accepted for this
/// placeholder; the Undo button is the second path.
class CaptureScreen extends ConsumerStatefulWidget {
  const CaptureScreen({super.key});

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends ConsumerState<CaptureScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _capture(String line) async {
    final store = ref.read(tasksProvider.notifier).store;
    await store.quickCapture(line, today: ref.read(todayProvider));
    if (!mounted) return;
    _controller.clear();
    _focus.requestFocus();
  }

  Future<void> _undo() async {
    if (!ref.read(canUndoProvider)) return;
    await ref.read(tasksProvider.notifier).store.undo();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undo,
      },
      child: Scaffold(
        body: switch (ref.watch(tasksProvider)) {
          AsyncData(:final value) => _loaded(value),
          AsyncError(:final error) => Center(
            child: Text('archive error: $error'),
          ),
          // Plain text on purpose: an endless spinner animation would
          // keep widget-test pumps from ever settling.
          _ => const Center(child: Text('opening the archive…')),
        },
      ),
    );
  }

  Widget _loaded(TaskProjection projection) {
    final today = ref.watch(todayProvider);
    final inbox = projection.list(TaskList.inbox, today: today);
    final todayList = projection.list(TaskList.today, today: today);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: true,
                  onSubmitted: _capture,
                  decoration: const InputDecoration(
                    hintText:
                        'Capture to Inbox — Enter saves, '
                        '@today !2026-09-01',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: ref.watch(canUndoProvider) ? _undo : null,
                child: const Text('Undo'),
              ),
            ],
          ),
        ),
        Expanded(
          child: inbox.isEmpty && todayList.isEmpty
              ? Center(child: Text(ref.watch(shellGreetingProvider)))
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    _header(context, 'Inbox', inbox.length),
                    for (final task in inbox) _row(task, today),
                    _header(context, 'Today', todayList.length),
                    for (final task in todayList) _row(task, today),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, String list, int count) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(
      '$list ($count)',
      style: Theme.of(context).textTheme.titleSmall,
    ),
  );

  Widget _row(Task task, CalendarDate today) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text(formatQuickCapture(task, today: today)),
  );
}
