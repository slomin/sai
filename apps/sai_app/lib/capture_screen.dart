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
  String _notice = '';

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _capture(String line) async {
    // Clear before the append settles: a key-repeated Enter resubmits an
    // empty line, which captures nothing, instead of the same line twice.
    _controller.clear();
    try {
      final store = ref.read(tasksProvider.notifier).store;
      await store.quickCapture(line, today: ref.read(todayProvider));
      if (!mounted) return;
      setState(() => _notice = '');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        // Give the line back rather than losing it.
        _controller.text = line;
        _notice = 'capture failed: $error';
      });
    } finally {
      if (mounted) _focus.requestFocus();
    }
  }

  Future<void> _undo() async {
    if (!ref.read(canUndoProvider)) return;
    try {
      await ref.read(tasksProvider.notifier).store.undo();
      if (!mounted) return;
      setState(() => _notice = '');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _notice = 'undo failed: $error');
    }
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
    final sections = captureSections(projection, today);
    final empty = sections.every((section) => section.tasks.isEmpty);
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
                    hintText: captureHint,
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
        if (_notice.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(_notice),
          ),
        Expanded(
          child: empty
              ? Center(child: Text(ref.watch(shellGreetingProvider)))
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final section in sections) ...[
                      _header(context, section),
                      for (final task in section.tasks) _row(task, today),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, CaptureSection section) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(section.label, style: Theme.of(context).textTheme.titleSmall),
  );

  Widget _row(Task task, CalendarDate today) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text(formatQuickCapture(task, today: today)),
  );
}
