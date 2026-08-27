import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../commands.dart';
import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import '../things/import_flow.dart';
import '../widgets/eyebrow.dart';
import '../widgets/sai_dialog.dart';
import '../workspace/task_commands.dart';

/// The welcome and its two choices, for tests.
const firstRunKey = Key('first-run');
const startEmptyKey = Key('start-empty');
const importFromThingsKey = Key('import-from-things');

/// Whether this run has been through setup, whatever the file says: a
/// refused settings write must not trap a person in the welcome.
final setupSeenProvider = NotifierProvider<SetupSeen, bool>(SetupSeen.new);

class SetupSeen extends Notifier<bool> {
  @override
  bool build() => false;

  void mark() => state = true;
}

/// The first-run choice (#40), over the shell rather than as a route so
/// the shell stays mounted behind it: shown while setup was never
/// completed and the archive holds nothing. "Start empty" and a finished
/// import both mark setup done — a deliberate act, so the write is
/// warranted (ADR 0015) — and land in the Inbox with capture focused.
class FirstRunGate extends ConsumerWidget {
  const FirstRunGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final seen = ref.watch(setupSeenProvider);
    final projection = ref.watch(tasksProvider);
    final fresh =
        !settings.setupDone &&
        !seen &&
        projection is AsyncData<TaskProjection> &&
        projection.value.eventCount == 0;
    if (!fresh) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        const ModalBarrier(dismissible: false, color: Colors.black38),
        FocusScope(
          autofocus: true,
          child: Center(child: _Welcome(problem: settings.problem)),
        ),
      ],
    );
  }
}

class _Welcome extends ConsumerWidget {
  const _Welcome({required this.problem});

  final String? problem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = context.saiText;
    return SaiDialog(
      key: firstRunKey,
      eyebrow: 'Welcome',
      title: 'Start empty, or bring Things over',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'sai keeps every task and every change as a line in its own '
            'archive. Start with nothing and capture as you go, or import '
            'from Things 3 — a preview first, then only what is new.',
            style: text.bodyDim,
          ),
          if (problem case final problem?) ...[
            const SizedBox(height: 10),
            const Eyebrow('Settings', dim: true),
            Text(problem, style: text.note.copyWith(color: SaiColors.redInk)),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: importFromThingsKey,
          onPressed: () async {
            final container = ProviderScope.containerOf(context, listen: false);
            if (await showImportFlow(context)) finishSetup(container);
          },
          child: const Text('Import from Things 3…'),
        ),
        Focus(
          autofocus: true,
          child: SaiPrimaryButton(
            key: startEmptyKey,
            label: 'Start empty',
            onPressed: () =>
                finishSetup(ProviderScope.containerOf(context, listen: false)),
          ),
        ),
      ],
    );
  }
}

/// Marks setup done and lands in the Inbox with the capture field ready.
/// A refused write (a newer sai's file) is said in the bar; the welcome
/// still goes, for this run.
void finishSetup(ProviderContainer container) {
  container.read(setupSeenProvider.notifier).mark();
  try {
    container.read(settingsProvider.notifier).markSetupDone();
  } on Object catch (error) {
    container
        .read(noticeProvider.notifier)
        .show('could not save the setup: ${describeFailure(error)}');
  }
  container
      .read(selectedSectionProvider.notifier)
      .select(const ListSection(TaskList.inbox));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    container.read(captureFocusProvider).requestFocus();
  });
}
