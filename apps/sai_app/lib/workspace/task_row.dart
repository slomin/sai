import 'package:flutter/material.dart';
import 'package:sai_core/sai_core.dart';

import '../theme/motion.dart';
import '../theme/sai_theme.dart';
import '../theme/sai_tokens.dart';
import '../widgets/check_mark.dart';
import '../widgets/chip.dart';
import '../widgets/glyph_button.dart';
import 'task_row_chips.dart';

/// The key of a task's row, and of its cancel affordance, for tests.
Key taskRowKey(TaskId task) => ValueKey('row-$task');

/// Scrolls [context]'s row into view where it is not already: up to the
/// top when it sits above the viewport, down to the bottom when below,
/// and not at all when it is on screen — so a key, a click and a Quick
/// Find open all land the same way (#89).
void revealRow(BuildContext context) {
  if (Scrollable.maybeOf(context) == null) return;
  Scrollable.ensureVisible(
    context,
    alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
  );
  Scrollable.ensureVisible(
    context,
    alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
  );
}

Key cancelButtonKey(TaskId task) => ValueKey('cancel-$task');

/// How a leaving row is going: it confirms the action, then collapses.
enum RowFinish { completed, cancelled }

/// One task as the reference draws it: the square check, the title (and
/// the first line of the notes), the chips on the right. Click selects;
/// the check completes; the cross that appears on hover cancels.
///
/// Motion (#72): a row entering the list grows in; a row that was just
/// completed or cancelled fills its mark, holds long enough to read the
/// confirmation, then collapses — surrounding rows never jump. Every
/// duration resolves through [SaiMotion].
class TaskRow extends StatefulWidget {
  const TaskRow({
    super.key,
    required this.task,
    required this.chips,
    required this.selected,
    this.finishing,
    this.entering = false,
    this.onSelect,
    this.onCheck,
    this.onCancel,
    this.onGone,
    this.gutter,
  });

  final Task task;
  final List<ChipSpec> chips;
  final bool selected;

  /// Set on the ghost of a row whose task just left the list.
  final RowFinish? finishing;
  final bool entering;
  final VoidCallback? onSelect;
  final VoidCallback? onCheck;
  final VoidCallback? onCancel;

  /// Called once a finishing row has collapsed away.
  final VoidCallback? onGone;

  /// Wraps the check gutter — a drag-start listener where the list can be
  /// reordered.
  final Widget Function(Widget child)? gutter;

  @override
  State<TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<TaskRow> with TickerProviderStateMixin {
  late final AnimationController _size;
  AnimationController? _hold;
  var _hovered = false;

  @override
  void initState() {
    super.initState();
    _size = AnimationController(
      vsync: this,
      value: widget.entering ? 0 : 1,
      duration: SaiDurations.enter,
    );
    if (widget.selected) _reveal();
  }

  @override
  void didUpdateWidget(TaskRow old) {
    super.didUpdateWidget(old);
    if (widget.selected && !old.selected) _reveal();
  }

  /// After the frame that laid the row out (a row built selected has no
  /// size yet); a row leaving the list is not brought back for it.
  void _reveal() {
    if (widget.finishing != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) revealRow(context);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _size.duration = SaiMotion.resolve(context, SaiDurations.enter);
    if (widget.entering && _size.value < 1 && !_size.isAnimating) {
      _size.forward();
    }
    if (widget.finishing != null && _hold == null) _startLeaving();
  }

  void _startLeaving() {
    final hold = _hold = AnimationController(
      vsync: this,
      duration: SaiMotion.resolve(context, SaiDurations.hold),
    );
    hold.forward().whenComplete(() {
      if (!mounted) return;
      _size.duration = SaiMotion.resolve(context, SaiDurations.collapse);
      _size.reverse().whenComplete(_gone);
    });
  }

  var _reportedGone = false;

  void _gone() {
    if (_reportedGone) return;
    _reportedGone = true;
    widget.onGone?.call();
  }

  @override
  void dispose() {
    // A collapsed row is a zero-extent leading child, which the sliver
    // collects before the animation's future settles — so the report goes
    // out from here as well, after the frame that dropped the row.
    if (widget.finishing != null && !_reportedGone) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _gone());
    }
    _hold?.dispose();
    _size.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final text = context.saiText;
    final finishing = widget.finishing;
    final finished = finishing != null || task.status != TaskStatus.open;
    final cancelled =
        finishing == RowFinish.cancelled || task.status == TaskStatus.cancelled;
    final note = task.notes.split('\n').first.trim();
    final chips = finishing == null
        ? widget.chips
        : [
            ChipSpec(
              finishing == RowFinish.completed ? 'COMPLETED' : 'CANCELLED',
              ChipTone.tonal,
            ),
          ];
    final label = StringBuffer(task.title);
    if (finished) label.write(cancelled ? ', cancelled' : ', completed');
    if (widget.selected) label.write(', selected');

    Widget check = CheckMark(
      checked: finished && !cancelled,
      cancelled: cancelled,
      onTap: finishing == null ? widget.onCheck : null,
      semanticLabel: finished
          ? 'Reopen ${task.title}'
          : 'Complete ${task.title}',
    );
    if (widget.gutter case final gutter?) check = gutter(check);

    final row = Semantics(
      label: label.toString(),
      selected: widget.selected,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onSelect,
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.fromLTRB(22, 10, 22, 10),
            decoration: BoxDecoration(
              color: widget.selected
                  ? SaiColors.surf
                  : _hovered
                  ? SaiColors.surf.withValues(alpha: 0.6)
                  : null,
              border: const Border(bottom: BorderSide(color: SaiColors.rule)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                check,
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        task.title,
                        style: text.body.copyWith(
                          fontWeight: FontWeight.w500,
                          fontVariations: const [FontVariation.weight(500)],
                          color: finished ? SaiColors.inkFaint : SaiColors.ink,
                          decoration: finished
                              ? TextDecoration.lineThrough
                              : null,
                          decorationColor: SaiColors.inkFaint,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (note.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            note,
                            style: text.note,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // The chips share the width with the title and wrap
                // inside their share, so a long title or large text never
                // pushes them out of the row.
                Flexible(
                  flex: 2,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    alignment: WrapAlignment.end,
                    children: [
                      for (final chip in chips)
                        SaiChip(chip.text, tone: chip.tone),
                    ],
                  ),
                ),
                if (widget.onCancel != null && finishing == null && !finished)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Opacity(
                      opacity: _hovered || widget.selected ? 1 : 0,
                      child: GlyphButton(
                        key: cancelButtonKey(task.id),
                        glyph: '✕',
                        label: 'Cancel ${task.title}',
                        color: SaiColors.inkFaint,
                        size: 13,
                        minSize: 30,
                        onPressed: widget.onCancel,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    return SizeTransition(
      sizeFactor: _size,
      alignment: Alignment.topCenter,
      child: row,
    );
  }
}
