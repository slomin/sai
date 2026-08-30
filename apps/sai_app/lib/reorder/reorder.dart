import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/motion.dart';
import '../theme/sai_tokens.dart';
import 'drag_handle.dart';

/// What a drag carries: the id being moved and the group it may land in.
class ReorderPayload<T extends Object> {
  const ReorderPayload(this.id, this.group);

  final T id;
  final Object group;
}

/// The slot a drag is over: above or below a row.
typedef ReorderSlot<T> = ({T target, bool below});

/// One reorderable group (#98) — the rows of a section, a project's
/// headings, the live areas, the projects of one area — and the drag
/// that may be live in it. Owned by the surface that shows the group,
/// handed to each of its [ReorderRow]s; the rows are targets, the handle
/// on each is the draggable. A drop turns the slot into an anchor the
/// store understands — the nearest row above the slot that [canAnchor]
/// — and hands it to [onDrop]; a drop that would leave the row where it
/// is writes nothing.
///
/// Every group has its own mechanic rather than Flutter's
/// `SliverReorderableList`: that one animates its gap and drop over a
/// fixed 250 ms with no way to honour Reduce Motion, and cannot host
/// rows nested under other rows (the sidebar) or headers between lists
/// (a project's headings).
class ReorderController<T extends Object> extends ChangeNotifier {
  ReorderController({
    required this.group,
    required this.onDrop,
    required this.refusal,
    this.onRefused,
  });

  /// What a payload must carry to land here.
  final Object group;

  /// Applies a drop: [moved] goes after [after], or first when null.
  final Future<void> Function(T moved, T? after) onDrop;

  /// Why a drag from another group cannot land here — the sentence the
  /// notice shows when it is dropped anyway.
  final String refusal;

  /// Shows a refusal; the surface routes it to the notice.
  final void Function(String reason)? onRefused;

  /// The rows of the group, top to bottom, as of the last build.
  List<T> order = const [];

  /// Whether a row can be the anchor of a move: live and open, not a
  /// ghost — the store refuses the rest.
  bool Function(T id) canAnchor = (_) => true;

  T? dragging;
  ReorderSlot<T>? slot;
  EdgeDraggingAutoScroller? _scroller;

  /// The refusal a foreign target last answered a live drag with, so the
  /// source can say it when the drag is dropped there.
  static String? _refused;

  void begin(T id) {
    dragging = id;
    slot = null;
    _refused = null;
    notifyListeners();
  }

  /// A drag is over [target], in its upper or lower half; the list
  /// scrolls when the proxy nears its edge.
  void hover(
    T target, {
    required bool below,
    required ScrollableState? scrollable,
    required Rect proxy,
  }) {
    final next = (target: target, below: below);
    if (slot != next) {
      slot = next;
      notifyListeners();
    }
    if (scrollable != null) {
      _scroller ??= EdgeDraggingAutoScroller(scrollable, velocityScalar: 30);
      _scroller!.startAutoScrollIfNecessary(proxy);
    }
  }

  void leave(T target) {
    if (slot?.target != target) return;
    slot = null;
    notifyListeners();
  }

  /// A foreign drag is over this group: the reason it cannot land is
  /// kept for the source, in case it is dropped here anyway; a row of
  /// the drag's own group forgets it again.
  void refuse() => _refused = refusal;

  static void unrefuse() => _refused = null;

  /// A foreign target was left. The drop leaves every target in the
  /// same call that tells the source it was cancelled, so the reason
  /// survives that; a drag that genuinely moves on has it cleared once
  /// this event is over.
  static void unrefuseAfterLeave() {
    final reason = _refused;
    if (reason == null) return;
    scheduleMicrotask(() {
      if (identical(_refused, reason)) _refused = null;
    });
  }

  /// The source's drag ended without a target taking it: a foreign
  /// group's refusal is what happened, if one was over it.
  void cancelled() {
    final reason = _refused;
    end();
    if (reason != null) onRefused?.call(reason);
  }

  void end() {
    _scroller?.stopAutoScroll();
    _scroller = null;
    dragging = null;
    slot = null;
    _refused = null;
    notifyListeners();
  }

  /// The anchor [moved] lands after when dropped at [at]: null for
  /// first; the sentinel [noMove] when the slot would leave it where it
  /// is or is the row itself.
  Object? anchorFor(T moved, ReorderSlot<T> at) {
    if (at.target == moved) return noMove;
    final ids = [
      for (final id in order)
        if (id != moved) id,
    ];
    final i = ids.indexOf(at.target);
    if (i < 0) return noMove;
    final insertion = at.below ? i + 1 : i;
    T? after;
    for (var k = insertion - 1; k >= 0; k--) {
      if (canAnchor(ids[k])) {
        after = ids[k];
        break;
      }
    }
    // Where it stands now, by the same rule: nothing to write.
    final here = order.indexOf(moved);
    T? current;
    for (var k = here - 1; k >= 0; k--) {
      if (canAnchor(order[k])) {
        current = order[k];
        break;
      }
    }
    return after == current ? noMove : after;
  }

  /// The drop landed on a row of this group.
  Future<void> drop() async {
    final moved = dragging;
    final at = slot;
    end();
    if (moved == null || at == null) return;
    final anchor = anchorFor(moved, at);
    if (identical(anchor, noMove)) return;
    await onDrop(moved, anchor as T?);
  }

  /// [anchorFor]'s answer when nothing would change.
  static const noMove = Object();
}

/// A row of a [ReorderController]'s group: a target for the group's own
/// drags, showing the slot above or below itself while one is over it,
/// and — when [enabled] — carrying the handle that starts a drag of its
/// own id. [builder] draws the row around the handle it is given (null
/// when the row cannot be dragged); the same builder draws the proxy
/// that follows the pointer, at the row's own width.
class ReorderRow<T extends Object> extends StatefulWidget {
  const ReorderRow({
    super.key,
    required this.controller,
    required this.id,
    required this.title,
    required this.enabled,
    required this.builder,
  });

  final ReorderController<T> controller;
  final T id;
  final String title;
  final bool enabled;
  final Widget Function(BuildContext context, Widget? handle) builder;

  @override
  State<ReorderRow<T>> createState() => _ReorderRowState<T>();
}

class _ReorderRowState<T extends Object> extends State<ReorderRow<T>> {
  RenderBox? get _box => context.findRenderObject() as RenderBox?;

  Rect _proxyRect(Offset origin) {
    final size = _box?.size ?? Size.zero;
    return origin & size;
  }

  /// The proxy is anchored at the row's own corner, so it lifts from
  /// where the row stood and its middle is what crosses the others.
  Offset _anchor(Draggable<Object> _, BuildContext _, Offset position) {
    final box = _box;
    if (box == null) return Offset.zero;
    return position - box.localToGlobal(Offset.zero);
  }

  Widget _feedback(BuildContext context) {
    final size = _box?.size;
    return SizedBox(
      width: size?.width,
      height: size?.height,
      child: Material(
        color: SaiColors.bg,
        elevation: 6,
        shadowColor: SaiColors.ink.withValues(alpha: 0.35),
        child: widget.builder(context, DragHandle(title: widget.title)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    Widget? handle;
    if (widget.enabled) {
      handle = Draggable<ReorderPayload<T>>(
        key: dragHandleKey(widget.id),
        data: ReorderPayload(widget.id, controller.group),
        affinity: Axis.vertical,
        hitTestBehavior: HitTestBehavior.opaque,
        dragAnchorStrategy: _anchor,
        feedback: Builder(builder: _feedback),
        childWhenDragging: Opacity(
          opacity: 0.35,
          child: DragHandle(title: widget.title),
        ),
        onDragStarted: () => controller.begin(widget.id),
        onDraggableCanceled: (_, _) => controller.cancelled(),
        onDragCompleted: () {
          // Taken by a target of this group, or of another (which refused
          // it and ends the drag here too).
          if (controller.dragging != null) controller.end();
        },
        child: DragHandle(title: widget.title),
      );
    }
    return DragTarget<ReorderPayload<T>>(
      onWillAcceptWithDetails: (details) {
        if (details.data.group != controller.group) {
          controller.refuse();
          return false;
        }
        ReorderController.unrefuse();
        return details.data.id != widget.id;
      },
      onMove: (details) {
        if (details.data.group != controller.group) return;
        final box = _box;
        if (box == null) return;
        final proxy = _proxyRect(details.offset);
        final middle = box.globalToLocal(proxy.center);
        controller.hover(
          widget.id,
          below: middle.dy > box.size.height / 2,
          scrollable: Scrollable.maybeOf(context),
          proxy: proxy,
        );
      },
      onLeave: (data) {
        if (data != null && data.group != controller.group) {
          ReorderController.unrefuseAfterLeave();
        }
        controller.leave(widget.id);
      },
      onAcceptWithDetails: (_) => controller.drop(),
      builder: (context, _, _) => ListenableBuilder(
        listenable: controller,
        builder: (context, child) {
          final slot = controller.slot;
          final dragging = controller.dragging == widget.id;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropGap(visible: slot?.target == widget.id && !slot!.below),
              Opacity(opacity: dragging ? 0.35 : 1, child: child),
              DropGap(visible: slot?.target == widget.id && slot!.below),
            ],
          );
        },
        child: widget.builder(context, handle),
      ),
    );
  }
}

/// The slot a drag would land in: a red rule that opens above or below
/// a row while the proxy is over it. It animates open over
/// [SaiDurations.gap], and under Reduce Motion appears in one frame —
/// still there, still red: the feedback stays, the motion goes.
class DropGap extends StatelessWidget {
  const DropGap({super.key, required this.visible});

  final bool visible;

  static const extent = 10.0;

  @override
  Widget build(BuildContext context) {
    final slot = SizedBox(
      height: visible ? extent : 0,
      child: visible
          ? const Center(
              child: SizedBox(
                height: 2,
                child: ColoredBox(color: SaiColors.red),
              ),
            )
          : null,
    );
    if (SaiMotion.reduced(context)) return slot;
    return AnimatedSize(
      duration: SaiDurations.gap,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: slot,
    );
  }
}
