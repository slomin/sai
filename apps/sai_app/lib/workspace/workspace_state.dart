import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../commands.dart';
import 'task_commands.dart';

/// How long after the last change the workspace is written: long enough
/// to fold a run of clicks into one write, short enough to beat ⌘Q.
const workspaceSaveDelay = Duration(milliseconds: 400);

/// Brings the workspace back to where it was left and keeps settings
/// current as it moves (#76, ADR 0015). Sits above the shell, so it is
/// there before the list pane's own listeners are.
///
/// Restoring is two steps: the assistant pane and the folded areas need
/// no projection and apply at once, so nothing flashes; the section and
/// the task wait for the projection, are checked against it, and go in
/// that order — the pane clears a selection its section does not show.
/// Saving is an effect on the composed [workspaceStateProvider], debounced
/// with a timer and flushed when the app is asked to quit; a file that
/// refuses to be written says so once in the notice and is left alone
/// after that.
class WorkspaceRestorer extends ConsumerStatefulWidget {
  const WorkspaceRestorer({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<WorkspaceRestorer> createState() => _WorkspaceRestorerState();
}

class _WorkspaceRestorerState extends ConsumerState<WorkspaceRestorer> {
  Timer? _pending;
  var _restored = false;
  var _writable = true;
  late final AppLifecycleListener _lifecycle;

  // Reads go through the container, as `AppCommands` does: the exit flush
  // runs from a lifecycle callback, outside any build.
  late final ProviderContainer _container;

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        _flush();
        return AppExitResponse.exit;
      },
    );
    // Providers may not change while the tree is building, and the first
    // build is where this state begins; the frame it waits for is the
    // shell's "opening the archive…", so nothing the person sees moves.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final saved = ref.read(settingsProvider).workspace;
      if (saved.assistantVisible case final shown?) {
        ref.read(chatVisibleProvider.notifier).set(shown);
      }
      ref.listenManual(tasksProvider, fireImmediately: true, (_, next) {
        final projection = next.value;
        if (_restored || projection == null) return;
        _restore(saved, projection);
      });
    });
  }

  void _restore(WorkspaceState saved, TaskProjection projection) {
    _restored = true;
    final restored = restoreWorkspace(
      projection,
      section: saved.section,
      task: saved.task,
      collapsedAreas: saved.collapsedAreas,
      today: ref.read(todayProvider),
    );
    ref.read(collapsedAreasProvider.notifier).set(restored.collapsedAreas);
    ref.read(selectedSectionProvider.notifier).select(restored.section);
    if (restored.task case final task?) {
      ref.read(selectedTaskProvider.notifier).select(task);
    }
    // What was saved and what could be restored may differ — a stale id,
    // a folded area that is gone — and a restore that changes nothing
    // notifies nobody, so the clean copy is written from here.
    if (ref.read(workspaceStateProvider) != saved) _schedule();
  }

  void _schedule() {
    _pending?.cancel();
    _pending = Timer(workspaceSaveDelay, _flush);
  }

  void _flush() {
    _pending?.cancel();
    _pending = null;
    if (!_restored || !_writable) return;
    final notice = _container.read(noticeProvider.notifier);
    try {
      _container
          .read(settingsProvider.notifier)
          .setWorkspace(_container.read(workspaceStateProvider));
    } on StateError catch (error) {
      // A newer sai's file: every write would refuse, so stop asking.
      _writable = false;
      notice.show('could not save the workspace: ${describeFailure(error)}');
    } on Object catch (error) {
      notice.show('could not save the workspace: ${describeFailure(error)}');
    }
  }

  @override
  void dispose() {
    // No flush here: a provider must not change while the tree is being
    // torn down, and the app's own exit runs through the lifecycle
    // listener above.
    _pending?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(workspaceStateProvider, (_, _) {
      if (_restored) _schedule();
    });
    return widget.child;
  }
}
