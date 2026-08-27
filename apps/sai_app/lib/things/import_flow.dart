import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../platform/finder.dart';
import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import '../widgets/eyebrow.dart';
import '../widgets/sai_dialog.dart';
import '../widgets/sai_toggle.dart';

/// The flow's controls, for tests.
const importFlowKey = Key('import-flow');
const importChooseKey = Key('import-choose');
const importPreviewKey = Key('import-preview');
const importRunKey = Key('import-run');
const importDoneKey = Key('import-done');
const importBackKey = Key('import-back');
const importCloseKey = Key('import-close');
const importRetryKey = Key('import-retry');
const importProgressKey = Key('import-progress');
const importOpenOnlyKey = Key('import-open-only');
const importSkipRepeatKey = Key('import-skip-repeat');

/// Runs the Things import (#40) as one dialog over [thingsImportProvider]:
/// find or choose the database, preview what a run would do, run it,
/// read the counts. Resolves true when a run finished. Every failure
/// names its next step; a run in progress cannot be dismissed, so a
/// half-applied plan is seen, never hidden.
Future<bool> showImportFlow(BuildContext context) async {
  final done = await showDialog<bool>(
    context: context,
    builder: (context) => const ImportFlow(),
  );
  return done ?? false;
}

class ImportFlow extends ConsumerStatefulWidget {
  const ImportFlow({super.key});

  @override
  ConsumerState<ImportFlow> createState() => _ImportFlowState();
}

class _ImportFlowState extends ConsumerState<ImportFlow> {
  var _openOnly = false;
  var _skipRepeat = false;

  late final ThingsImportNotifier _import;

  @override
  void initState() {
    super.initState();
    _import = ref.read(thingsImportProvider.notifier);
    // A fresh flow each time it opens — unless a run is still going, in
    // which case the dialog shows it — and the locate that opening asks
    // for. After the first frame: a provider may not change while the
    // tree builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(thingsImportProvider) is ImportRunning) return;
      _import.reset();
      _import.locate();
    });
  }

  ThingsImportOptions get _options =>
      ThingsImportOptions(openOnly: _openOnly, skipRepeatHistory: _skipRepeat);

  Future<void> _choose() async {
    final path = await ref
        .read(finderProvider)
        .chooseFile(prompt: 'Choose the Things database (main.sqlite)');
    if (path != null) _import.useDatabase(path);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(thingsImportProvider);
    final running = state is ImportRunning;
    return PopScope(
      canPop: !running,
      child: KeyedSubtree(
        key: importFlowKey,
        child: switch (state) {
          ImportIdle() => _frame(
            title: 'Looking for Things…',
            body: const SizedBox.shrink(),
            actions: [_close()],
          ),
          ImportSource(:final path) => _source(path),
          ImportReading(:final path) => _frame(
            title: 'Reading a private copy…',
            body: _path(path),
            actions: const [],
          ),
          ImportPlanned(:final path, :final result) => _planned(path, result),
          ImportRunning(:final done, :final total) => _frame(
            title: 'Importing…',
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(
                  key: importProgressKey,
                  value: total == 0 ? 0 : done / total,
                  color: SaiColors.red,
                  backgroundColor: SaiColors.surf3,
                ),
                const SizedBox(height: 8),
                Text('$done of $total operations', style: context.saiText.meta),
              ],
            ),
            actions: const [],
          ),
          ImportDone(:final result) => _done(result),
          ImportFailed(:final failure, :final path) => _failed(failure, path),
        },
      ),
    );
  }

  Widget _frame({
    required String title,
    required Widget body,
    required List<Widget> actions,
  }) => SaiDialog(
    eyebrow: 'Import from Things 3',
    title: title,
    body: body,
    actions: actions,
  );

  Widget _close() => TextButton(
    key: importCloseKey,
    onPressed: () => Navigator.of(context).pop(false),
    child: const Text('Close'),
  );

  Widget _path(String path) => Text(
    path,
    style: mono(12, color: SaiColors.inkDim),
    maxLines: 3,
    overflow: TextOverflow.ellipsis,
  );

  Widget _source(String path) {
    final text = context.saiText;
    return _frame(
      title: 'Preview before anything is written',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _path(path),
          const SizedBox(height: 10),
          Text(
            'sai reads a private copy of the database and shows what a run '
            'would do. Things itself is never written to; run it again later '
            'and only the differences land.',
            style: text.note,
          ),
          const SizedBox(height: 12),
          _option(
            key: importOpenOnlyKey,
            label: 'Open tasks only',
            helper: 'Leave completed and cancelled tasks behind',
            value: _openOnly,
            onChanged: (v) => setState(() => _openOnly = v),
          ),
          _option(
            key: importSkipRepeatKey,
            label: 'Skip repeat history',
            helper: 'No finished instances of repeating tasks',
            value: _skipRepeat,
            onChanged: (v) => setState(() => _skipRepeat = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: importChooseKey,
          onPressed: _choose,
          child: const Text('Choose…'),
        ),
        _close(),
        SaiPrimaryButton(
          key: importPreviewKey,
          label: 'Preview',
          onPressed: () => _import.preview(_options),
        ),
      ],
    );
  }

  Widget _option({
    required Key key,
    required String label,
    required String helper,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final text = context.saiText;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: text.body),
                Text(helper, style: text.note),
              ],
            ),
          ),
          SaiToggle(key: key, value: value, onChanged: onChanged, label: label),
        ],
      ),
    );
  }

  Widget _planned(String path, ThingsImportResult result) {
    final text = context.saiText;
    final plan = result.plan;
    final report = result.report;
    final line = plan.isEmpty
        ? report.unsupported.isEmpty
              ? 'Nothing to do — sai already matches Things.'
              : 'Nothing to do — sai already holds everything this run would '
                    'import; the rows below stay behind.'
        : '${plan.length} operations would run. Nothing is written yet.';
    return _frame(
      title: plan.isEmpty ? 'Nothing to import' : 'What a run would do',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _path(path),
          const SizedBox(height: 10),
          _counts(report),
          const SizedBox(height: 10),
          Text(line, style: text.bodyDim),
        ],
      ),
      actions: [
        TextButton(
          key: importBackKey,
          onPressed: () => _import.useDatabase(path),
          child: const Text('Back'),
        ),
        _close(),
        SaiPrimaryButton(
          key: importRunKey,
          label: 'Import',
          onPressed: plan.isEmpty ? null : _import.run,
        ),
      ],
    );
  }

  Widget _done(ThingsImportResult result) {
    final text = context.saiText;
    return _frame(
      title: 'Imported',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _counts(result.report),
          const SizedBox(height: 10),
          Text(
            '${result.plan.length} operations, ${result.eventsAppended} '
            'events appended to the archive.',
            style: text.bodyDim,
          ),
        ],
      ),
      actions: [
        SaiPrimaryButton(
          key: importDoneKey,
          label: 'Done',
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }

  Widget _failed(ThingsFailure failure, String? path) {
    final text = context.saiText;
    final retryable = path != null && failure is! ThingsNotADatabase;
    return _frame(
      title: failure.headline,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (path != null) ...[_path(path), const SizedBox(height: 10)],
          Text(failure.nextAction, style: text.body),
        ],
      ),
      actions: [
        TextButton(
          key: importChooseKey,
          onPressed: _choose,
          child: const Text('Choose…'),
        ),
        _close(),
        if (retryable)
          SaiPrimaryButton(
            key: importRetryKey,
            label: 'Try again',
            onPressed: () => _import.preview(_options),
          ),
      ],
    );
  }

  /// The report as the reference's stat tiles: counts only.
  Widget _counts(ImportReport report) {
    final text = context.saiText;
    Widget row(String kind, KindCounts c) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 80, child: Text(kind, style: text.small)),
          Expanded(
            child: Text(
              '${c.created} new · ${c.updated} updated · ${c.unchanged} '
              'unchanged',
              style: text.meta,
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Eyebrow('Imported', dim: true),
        const SizedBox(height: 4),
        row('Areas', report.areas),
        row('Tags', report.tags),
        row('Projects', report.projects),
        row('Headings', report.headings),
        row('Tasks', report.tasks),
        if (report.unsupported.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Eyebrow('Not imported', dim: true),
          const SizedBox(height: 4),
          for (final entry in report.unsupported.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text(
                '${entry.value} · ${unsupportedLabel(entry.key)}',
                style: text.note,
              ),
            ),
        ],
      ],
    );
  }
}
