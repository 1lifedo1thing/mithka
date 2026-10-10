//
//  sticker_reorder_grid.dart
//
//  A lazy, long-press drag-reorderable sticker grid, the gesture Telegram
//  clients use to reorder stickers in a pack. Flutter has no built-in
//  reorderable grid, so this pairs one SliverGrid of [LongPressDraggable]
//  cells with drop resolution computed from the live cell geometry: the drop
//  target is the cell under the pointer when the drag ends, matched against
//  each mounted cell's rectangle. The grid stays lazy — only painted cells
//  participate in the drop math, and dragging near an edge auto-scrolls so
//  off-screen rows can be reached.
//
//  Motion contract: no tickers, no AnimationControllers. Reduced motion
//  disables dragging entirely (the hosting screen keeps its non-drag
//  Move earlier / Move later actions as the fallback), so the component can
//  never start an animation on a deactivated element.
//

import 'dart:async';

import 'package:flutter/material.dart';

/// Persists a reorder; [newIndex] is the final position of the dragged item
/// after it is removed from [oldIndex] (i.e. the index of the cell it was
/// dropped on, insert-after-removal semantics).
typedef StickerReorderCallback =
    Future<void> Function(int oldIndex, int newIndex);

/// A drag-reorderable sliver grid.
///
/// [itemCount] is the number of cells in the grid; [reorderableCount] caps the
/// drop target so trailing non-sticker tiles (the add tile) can never be a
/// destination. [cellBuilder] builds cell [index]'s content; the component
/// supplies the drag wrapper.
class StickerReorderGridSliver extends StatefulWidget {
  const StickerReorderGridSliver({
    super.key,
    required this.itemCount,
    required this.reorderableCount,
    required this.cellBuilder,
    required this.onReorder,
    this.crossAxisCount = 4,
    this.spacing = 10,
    this.dragEnabled = true,
    this.scrollController,
    this.viewportKey,
    this.edgeAutoscrollInset = 56,
  });

  final int itemCount;
  final int reorderableCount;
  final Widget Function(BuildContext context, int index) cellBuilder;
  final StickerReorderCallback onReorder;
  final int crossAxisCount;
  final double spacing;
  final bool dragEnabled;

  /// Scroll controller of the hosting scroll view; when provided together
  /// with [viewportKey], dragging near the viewport edge scrolls it.
  final ScrollController? scrollController;
  final GlobalKey? viewportKey;

  /// Height band at the top and bottom of the viewport where dragging
  /// auto-scrolls.
  final double edgeAutoscrollInset;

  @override
  State<StickerReorderGridSliver> createState() =>
      _StickerReorderGridSliverState();
}

class _StickerReorderGridSliverState extends State<StickerReorderGridSliver> {
  static const _autoscrollInterval = Duration(milliseconds: 110);

  final Map<int, GlobalKey> _cellKeys = {};
  int? _draggingIndex;
  Offset? _lastPointer;
  double _cellExtent = 0;
  bool _autoscrollingUp = false;
  bool _autoscrollingDown = false;
  Timer? _autoscrollTimer;

  GlobalKey _cellKey(int index) => _cellKeys.putIfAbsent(index, GlobalKey.new);

  bool get _effectiveDragEnabled =>
      widget.dragEnabled &&
      !(MediaQuery.maybeOf(context)?.disableAnimations ?? false);

  @override
  void didUpdateWidget(covariant StickerReorderGridSliver old) {
    super.didUpdateWidget(old);
    if (widget.itemCount < old.itemCount) {
      _cellKeys.removeWhere((index, _) => index >= widget.itemCount);
    }
    if (!_effectiveDragEnabled) _finishDrag();
  }

  @override
  void dispose() {
    _autoscrollTimer?.cancel();
    super.dispose();
  }

  Rect? _cellRect(int index) {
    final renderObject = _cellKeys[index]?.currentContext?.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      return null;
    }
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  /// The drop target for a global pointer position: the cell whose rectangle
  /// contains it, or the nearest mounted cell's center when the pointer is
  /// off every cell (above/below the viewport, between gaps).
  int? _targetIndex(Offset global) {
    if (widget.reorderableCount <= 0) return null;
    int? containing;
    var nearestIndex = -1;
    var nearestDistance = double.infinity;
    for (var index = 0; index < _cellKeys.length; index++) {
      final rect = _cellRect(index);
      if (rect == null) continue;
      if (rect.contains(global)) {
        containing ??= index;
        continue;
      }
      final distance = (rect.center - global).distanceSquared;
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearestIndex = index;
      }
    }
    final resolved = containing ?? (nearestIndex >= 0 ? nearestIndex : null);
    if (resolved == null) return null;
    return resolved.clamp(0, widget.reorderableCount - 1);
  }

  void _startDrag(int index) {
    if (!_effectiveDragEnabled) return;
    setState(() => _draggingIndex = index);
  }

  void _updateDrag(int index, DragUpdateDetails details) {
    _lastPointer = details.globalPosition;
    if (widget.scrollController == null || widget.viewportKey == null) return;
    final viewport =
        widget.viewportKey!.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.attached || !viewport.hasSize) return;
    final top = viewport.localToGlobal(Offset.zero).dy;
    final bottom = top + viewport.size.height;
    final y = details.globalPosition.dy;
    final up = y < top + widget.edgeAutoscrollInset;
    final down = y > bottom - widget.edgeAutoscrollInset;
    if (up == _autoscrollingUp && down == _autoscrollingDown) return;
    _autoscrollingUp = up;
    _autoscrollingDown = down;
    _syncAutoscrollTimer();
  }

  void _syncAutoscrollTimer() {
    final wantsScroll = _autoscrollingUp || _autoscrollingDown;
    if (!wantsScroll) {
      _autoscrollTimer?.cancel();
      _autoscrollTimer = null;
      return;
    }
    _autoscrollTimer ??= Timer.periodic(
      _autoscrollInterval,
      (_) => _autoscrollStep(),
    );
  }

  void _autoscrollStep() {
    final controller = widget.scrollController;
    if (controller == null ||
        !controller.hasClients ||
        _draggingIndex == null) {
      _autoscrollTimer?.cancel();
      _autoscrollTimer = null;
      return;
    }
    final position = controller.position;
    final step = _cellExtent > 0 ? _cellExtent + widget.spacing : 80.0;
    final delta = _autoscrollingUp ? -step : (_autoscrollingDown ? step : 0.0);
    if (delta == 0) return;
    final target = (controller.offset + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target != controller.offset) controller.jumpTo(target);
  }

  Future<void> _finishDrag() async {
    final oldIndex = _draggingIndex;
    final pointer = _lastPointer;
    _autoscrollTimer?.cancel();
    _autoscrollTimer = null;
    _autoscrollingUp = false;
    _autoscrollingDown = false;
    _lastPointer = null;
    if (_draggingIndex != null && mounted) {
      setState(() => _draggingIndex = null);
    }
    if (oldIndex == null || pointer == null) return;
    final target = _targetIndex(pointer);
    if (target == null || target == oldIndex) return;
    await widget.onReorder(oldIndex, target);
  }

  Widget _dragFeedback(BuildContext context, int index) {
    final border = BorderRadius.circular(12);
    return Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: border,
          boxShadow: const [
            BoxShadow(
              color: Color(0x55000000),
              blurRadius: 18,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: border,
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: widget.cellBuilder(context, index),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.crossAxisExtent;
      final extent =
          (width - widget.spacing * (widget.crossAxisCount - 1)) /
          widget.crossAxisCount;
      _cellExtent = extent;
      return SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: widget.crossAxisCount,
          mainAxisSpacing: widget.spacing,
          crossAxisSpacing: widget.spacing,
        ),
        itemCount: widget.itemCount,
        itemBuilder: (context, index) {
          final content = widget.cellBuilder(context, index);
          final key = _cellKey(index);
          if (!_effectiveDragEnabled || index >= widget.reorderableCount) {
            return SizedBox(key: key, width: extent, child: content);
          }
          return SizedBox(
            key: key,
            width: extent,
            child: LongPressDraggable<int>(
              data: index,
              maxSimultaneousDrags: 1,
              dragAnchorStrategy: pointerDragAnchorStrategy,
              onDragStarted: () => _startDrag(index),
              onDragUpdate: (details) => _updateDrag(index, details),
              onDraggableCanceled: (_, _) => unawaited(_finishDrag()),
              onDragEnd: (_) => unawaited(_finishDrag()),
              feedback: SizedBox(
                width: extent,
                height: extent,
                child: _dragFeedback(context, index),
              ),
              childWhenDragging: IgnorePointer(
                child: Opacity(opacity: 0.0, child: content),
              ),
              child: content,
            ),
          );
        },
      );
    },
  );
}
