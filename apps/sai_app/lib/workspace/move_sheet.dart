import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sai_core/sai_core.dart';

import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import '../widgets/eyebrow.dart';
import '../widgets/sai_dialog.dart';
import 'dates.dart';
import 'placement.dart';
import 'task_commands.dart';

/// The sheet and its options, for tests: a schedule option by its word
/// (`today`, `tomorrow`, `someday`, `date`, `none`), a place by its
/// [Placement].
const moveSheetKey = Key('move-sheet');
Key moveOptionKey(Object id) => ValueKey(('move-option', id));

/// Opens the Move / Schedule sheet (#98) on [task]: the two dimensions a
/// task moves in, side by side — when it is planned for, and where it is
/// filed — each a list of every destination, the current one marked. A
/// pick writes one event and closes the sheet; the other dimension and
/// the deadline are never touched. A refusal keeps the sheet up with the
/// store's reason under the list, so a stale destination never looks
/// like nothing happened.
Future<void> showMoveSheet(BuildContext context, TaskId task) =>
    showDialog<void>(
      context: context,
      builder: (context) => _MoveSheet(task: task),
    );

class _MoveSheet extends ConsumerStatefulWidget {
  const _MoveSheet({required this.task});

  final TaskId task;

  @override
  ConsumerState<_MoveSheet> createState() => _MoveSheetState();
}

class _MoveSheetState extends ConsumerState<_MoveSheet> {
  var _pending = false;
  String? _failure;

  Future<void> _commit(Future<String?> Function(TaskCommands) act) async {
    if (_pending) return;
    setState(() {
      _pending = true;
      _failure = null;
    });
    final failure = await act(ref.read(taskCommandsProvider));
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _pending = false;
      _failure = failure;
    });
  }

  Future<void> _schedule(TaskWhen when) =>
      _commit((commands) => commands.trySchedule(widget.task, when));

  Future<void> _place(Placement to) => _commit(
    (commands) => commands.tryMove(
      widget.task,
      project: to.project,
      area: to.area,
      heading: to.heading,
    ),
  );

  Future<void> _pickDate(Task task, CalendarDate today) async {
    final picked = await pickDate(
      context,
      eyebrow: 'When',
      title: 'Pick a day',
      initial: task.when is TaskWhenDate
          ? (task.when as TaskWhenDate).date
          : today,
    );
    if (picked != null) await _schedule(TaskWhen.date(picked));
  }

  @override
  Widget build(BuildContext context) {
    final projection = ref.watch(tasksProvider).value;
    final task = projection?.task(widget.task);
    if (projection == null || task == null) {
      // Gone from under the sheet (deleted elsewhere): nothing to move.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return const SizedBox.shrink();
    }
    final today = ref.watch(todayProvider);
    final text = context.saiText;
    final tomorrow = today.addDays(1);
    final when = task.when;
    final onDate = when is TaskWhenDate ? when.date : null;
    final current = placementOf(task);

    return PopScope(
      canPop: !_pending,
      child: SaiDialog(
        key: moveSheetKey,
        eyebrow: 'Move',
        title: task.title,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Eyebrow('Schedule', dim: true),
            const SizedBox(height: 6),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                _Option(
                  key: moveOptionKey('today'),
                  label: 'Today',
                  selected: onDate == today,
                  enabled: !_pending,
                  onPressed: () => _schedule(TaskWhen.date(today)),
                ),
                _Option(
                  key: moveOptionKey('tomorrow'),
                  label: 'Tomorrow',
                  selected: onDate == tomorrow,
                  enabled: !_pending,
                  onPressed: () => _schedule(TaskWhen.date(tomorrow)),
                ),
                _Option(
                  key: moveOptionKey('someday'),
                  label: 'Someday',
                  selected: when is TaskWhenSomeday,
                  enabled: !_pending,
                  onPressed: () => _schedule(TaskWhen.someday),
                ),
                _Option(
                  key: moveOptionKey('date'),
                  label: onDate != null && onDate != today && onDate != tomorrow
                      ? whenLabel(when, today: today)
                      : 'Pick a date…',
                  selected:
                      onDate != null && onDate != today && onDate != tomorrow,
                  enabled: !_pending,
                  onPressed: () => _pickDate(task, today),
                ),
                _Option(
                  key: moveOptionKey('none'),
                  label: 'No plan',
                  selected: when is TaskWhenNone,
                  enabled: !_pending,
                  onPressed: () => _schedule(TaskWhen.none),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Eyebrow('Place', dim: true),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  border: Border.symmetric(
                    horizontal: BorderSide(color: SaiColors.rule),
                  ),
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                    for (final option in placementOptions(projection))
                      _Option(
                        key: moveOptionKey(option.placement),
                        label: option.title,
                        prefix: switch (option.kind) {
                          PlacementKind.project when option.depth > 0 => '— ',
                          PlacementKind.heading => '· ',
                          _ => '',
                        },
                        depth: option.depth,
                        selected: option.placement == current,
                        enabled: !_pending,
                        onPressed: () => _place(option.placement),
                      ),
                  ],
                ),
              ),
            ),
            if (_failure case final failure?)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    failure,
                    key: dialogErrorKey,
                    style: text.meta.copyWith(color: SaiColors.red),
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _pending ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

/// One destination: a full-width line in the Place list, a pill in the
/// Schedule row; the current one is bold with a mark before it.
class _Option extends StatelessWidget {
  const _Option({
    super.key,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onPressed,
    this.prefix = '',
    this.depth,
  });

  final String label;
  final String prefix;
  final int? depth;
  final bool selected;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final text = context.saiText;
    final style = selected
        ? text.body.copyWith(
            fontWeight: FontWeight.w700,
            fontVariations: const [FontVariation.weight(700)],
          )
        : text.body;
    final line = Text(
      '$prefix$label',
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: enabled ? onPressed : null,
          borderRadius: const BorderRadius.all(
            Radius.circular(SaiRadius.small),
          ),
          child: depth == null
              ? Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: selected ? SaiColors.ink : SaiColors.rule,
                    ),
                    borderRadius: const BorderRadius.all(
                      Radius.circular(SaiRadius.small),
                    ),
                  ),
                  child: line,
                )
              : Padding(
                  padding: EdgeInsets.fromLTRB(8.0 + 16 * depth!, 5, 8, 5),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 14,
                        child: selected
                            ? Text('●', style: text.meta)
                            : const SizedBox.shrink(),
                      ),
                      Expanded(child: line),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
