import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

import 'package:jhentai/widget/photo_view/double_tap_drag_zoom_gesture_recognizer.dart';

typedef JScaleStateCycle = PhotoViewScaleState Function(PhotoViewScaleState);
typedef PhotoViewDoubleTapZoomEndCallback = void Function(
  BuildContext context,
  PhotoViewControllerValue controllerValue,
);

double _resolveScale(dynamic value, double fallback) {
  if (value is double) {
    return value;
  }
  if (value is PhotoViewComputedScale) {
    // PhotoViewComputedScale is essentially a wrapper around a double. When the
    // caller uses the enum we cannot resolve the size without the original
    // content dimensions, which are not available here. The reader only uses
    // literal doubles, so fall back to the provided default.
    return fallback;
  }
  return fallback;
}

class JPhotoView extends StatefulWidget {
  const JPhotoView({
    super.key,
    required this.child,
    this.childSize,
    this.backgroundDecoration,
    this.wantKeepAlive = false,
    this.controller,
    this.scaleStateController,
    this.minScale,
    this.maxScale,
    this.initialScale,
    this.scaleStateCycle,
    this.enableTapDragZoom = false,
    this.basePosition,
    this.tightMode,
    this.filterQuality,
    this.enableRotation = false,
    this.onTapUp,
    this.onTapDown,
    this.onScaleEnd,
    this.onDoubleTapZoomEnd,
  });

  final Widget? child;
  final Size? childSize;
  final BoxDecoration? backgroundDecoration;
  final bool wantKeepAlive;
  final PhotoViewController? controller;
  final PhotoViewScaleStateController? scaleStateController;
  final dynamic minScale;
  final dynamic maxScale;
  final dynamic initialScale;
  final JScaleStateCycle? scaleStateCycle;
  final bool enableTapDragZoom;
  final Alignment? basePosition;
  final bool? tightMode;
  final FilterQuality? filterQuality;
  final bool enableRotation;
  final PhotoViewImageTapUpCallback? onTapUp;
  final PhotoViewImageTapDownCallback? onTapDown;
  final PhotoViewImageScaleEndCallback? onScaleEnd;
  final PhotoViewDoubleTapZoomEndCallback? onDoubleTapZoomEnd;

  @override
  State<JPhotoView> createState() => _JPhotoViewState();
}

class _JPhotoViewState extends State<JPhotoView> with AutomaticKeepAliveClientMixin {
  late PhotoViewController _controller;
  late PhotoViewScaleStateController _scaleStateController;
  late bool _ownsController;
  late bool _ownsScaleStateController;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? PhotoViewController();
    _ownsScaleStateController = widget.scaleStateController == null;
    _scaleStateController = widget.scaleStateController ?? PhotoViewScaleStateController();
  }

  @override
  void didUpdateWidget(JPhotoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (_ownsController) {
        _controller.dispose();
      }
      _ownsController = widget.controller == null;
      _controller = widget.controller ?? PhotoViewController();
    }
    if (oldWidget.scaleStateController != widget.scaleStateController) {
      if (_ownsScaleStateController) {
        _scaleStateController.dispose();
      }
      _ownsScaleStateController = widget.scaleStateController == null;
      _scaleStateController = widget.scaleStateController ?? PhotoViewScaleStateController();
    }
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    if (_ownsScaleStateController) {
      _scaleStateController.dispose();
    }
    super.dispose();
  }

  @override
  bool get wantKeepAlive => widget.wantKeepAlive;

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (widget.child == null) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final Size size = constraints.biggest;
        final double initialScale = _resolveScale(widget.initialScale, 1.0);
        final double minScale = _resolveScale(widget.minScale, initialScale);
        final double maxScale = _resolveScale(widget.maxScale, math.max(initialScale, minScale));
        final Alignment basePosition = widget.basePosition ?? Alignment.center;

        final photoView = PhotoView.customChild(
          childSize: widget.childSize,
          backgroundDecoration: widget.backgroundDecoration,
          controller: _controller,
          scaleStateController: _scaleStateController,
          minScale: minScale,
          maxScale: maxScale,
          initialScale: initialScale,
          basePosition: basePosition,
          enableRotation: widget.enableRotation,
          tightMode: widget.tightMode,
          filterQuality: widget.filterQuality,
          wantKeepAlive: widget.wantKeepAlive,
          // Disable PhotoView's built-in double tap cycle so the overlay can
          // coordinate both double tap and double tap + drag behaviour.
          scaleStateCycle: null,
          onTapUp: widget.onTapUp,
          onTapDown: widget.onTapDown,
          onScaleEnd: widget.onScaleEnd,
          child: widget.child!,
        );

        return Stack(
          fit: StackFit.expand,
          children: [
            photoView,
            _TapDragZoomOverlay(
              controller: _controller,
              scaleStateController: _scaleStateController,
              size: size,
              minScale: minScale,
              maxScale: maxScale,
              initialScale: initialScale,
              basePosition: basePosition,
              enableTapDragZoom: widget.enableTapDragZoom,
              scaleStateCycle: widget.scaleStateCycle,
              onDoubleTapZoomEnd: widget.onDoubleTapZoomEnd,
              gestureBehavior: HitTestBehavior.translucent,
            ),
          ],
        );
      },
    );
  }
}

class _TapDragZoomOverlay extends StatefulWidget {
  const _TapDragZoomOverlay({
    required this.controller,
    required this.scaleStateController,
    required this.size,
    required this.minScale,
    required this.maxScale,
    required this.initialScale,
    required this.basePosition,
    required this.enableTapDragZoom,
    required this.scaleStateCycle,
    required this.onDoubleTapZoomEnd,
    required this.gestureBehavior,
  });

  final PhotoViewController controller;
  final PhotoViewScaleStateController scaleStateController;
  final Size size;
  final double minScale;
  final double maxScale;
  final double initialScale;
  final Alignment basePosition;
  final bool enableTapDragZoom;
  final JScaleStateCycle? scaleStateCycle;
  final PhotoViewDoubleTapZoomEndCallback? onDoubleTapZoomEnd;
  final HitTestBehavior gestureBehavior;

  @override
  State<_TapDragZoomOverlay> createState() => _TapDragZoomOverlayState();
}

class _TapDragZoomOverlayState extends State<_TapDragZoomOverlay> {
  Offset? _doubleTapLocalPosition;
  Offset? _normalizedLocalPosition;
  double? _scaleBefore;
  Offset? _positionBefore;
  bool _zooming = false;

  PhotoViewController get _controller => widget.controller;

  PhotoViewScaleStateController get _scaleStateController => widget.scaleStateController;

  PhotoViewControllerValue get _controllerValue => _controller.value;

  double get _currentScale => _controllerValue.scale ?? widget.initialScale;

  set _currentScale(double value) => _controller.scale = value;

  Offset get _currentPosition => _controllerValue.position;

  set _currentPosition(Offset value) => _controller.position = value;

  @override
  Widget build(BuildContext context) {
    if (!widget.enableTapDragZoom && widget.scaleStateCycle == null) {
      return const SizedBox.shrink();
    }

    return RawGestureDetector(
      behavior: widget.gestureBehavior,
      gestures: {
        DoubleTapDragZoomGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<DoubleTapDragZoomGestureRecognizer>(
          () => DoubleTapDragZoomGestureRecognizer(debugOwner: this),
          (DoubleTapDragZoomGestureRecognizer instance) {
            instance
              ..onDoubleTapDown = widget.scaleStateCycle != null ? _handleDoubleTapDown : null
              ..onDoubleTap = widget.scaleStateCycle != null ? _handleDoubleTap : null
              ..onDoubleTapCancel = widget.scaleStateCycle != null ? _handleDoubleTapCancel : null
              ..onZoomStart = widget.enableTapDragZoom ? _handleZoomStart : null
              ..onZoomUpdate = widget.enableTapDragZoom ? _handleZoomUpdate : null
              ..onZoomEnd = widget.enableTapDragZoom ? _handleZoomEnd : null;
          },
        ),
      },
    );
  }

  void _handleDoubleTapDown(TapDownDetails details) {
    _doubleTapLocalPosition = details.localPosition;
  }

  void _handleDoubleTap() {
    final JScaleStateCycle scaleStateCycle = widget.scaleStateCycle ??
        (state) => state == PhotoViewScaleState.initial
            ? PhotoViewScaleState.zoomedIn
            : PhotoViewScaleState.initial;

    final PhotoViewScaleState current = _scaleStateController.scaleState;
    PhotoViewScaleState next = scaleStateCycle(current);

    if (current == next) {
      // Avoid infinite loops if the custom cycle returns the same state.
      next = current == PhotoViewScaleState.initial
          ? PhotoViewScaleState.zoomedIn
          : PhotoViewScaleState.initial;
    }

    final double previousScale = _currentScale;
    final double targetScale = _scaleForState(next);

    _scaleStateController.scaleState = next;
    _applyScale(previousScale, targetScale, anchor: _doubleTapLocalPosition);
    widget.onDoubleTapZoomEnd?.call(context, _controller.value);
  }

  void _handleDoubleTapCancel() {
    _doubleTapLocalPosition = null;
  }

  void _handleZoomStart(TapDragZoomStartDetails details) {
    _zooming = true;
    _normalizedLocalPosition = details.localPoint;
    _scaleBefore = _currentScale;
    _positionBefore = _currentPosition;
  }

  void _handleZoomUpdate(TapDragZoomUpdateDetails details) {
    if (!_zooming || _normalizedLocalPosition == null || _scaleBefore == null) {
      return;
    }

    final double dy = details.localPoint.dy - _normalizedLocalPosition!.dy;
    final double deltaScale = dy / widget.size.height * 5;
    double newScale = (_scaleBefore ?? widget.initialScale) + deltaScale;
    newScale = newScale.clamp(widget.minScale, widget.maxScale);

    _currentScale = newScale;

    if ((_positionBefore ?? Offset.zero) == Offset.zero) {
      _currentPosition = _offsetForAnchor(_normalizedLocalPosition!, _scaleBefore!);
    }

    if (newScale <= widget.initialScale + 0.001) {
      _scaleStateController.scaleState = PhotoViewScaleState.initial;
    } else {
      _scaleStateController.scaleState = PhotoViewScaleState.zoomedIn;
    }
  }

  void _handleZoomEnd() {
    if (!_zooming) {
      return;
    }
    _zooming = false;

    double clampedScale = _currentScale.clamp(widget.minScale, widget.maxScale);
    _currentScale = clampedScale;

    if (clampedScale <= widget.initialScale + 0.001) {
      _scaleStateController.scaleState = PhotoViewScaleState.initial;
    } else {
      _scaleStateController.scaleState = PhotoViewScaleState.zoomedIn;
    }

    widget.onDoubleTapZoomEnd?.call(context, _controller.value);
  }

  void _applyScale(double from, double to, {Offset? anchor}) {
    _currentScale = to;
    if (anchor != null) {
      _currentPosition = _offsetForAnchor(anchor, to);
    } else {
      _currentPosition =
          _offsetForAnchor(Offset(widget.size.width / 2, widget.size.height / 2), to);
    }
  }

  double _scaleForState(PhotoViewScaleState state) {
    switch (state) {
      case PhotoViewScaleState.initial:
        return widget.initialScale;
      case PhotoViewScaleState.zoomedIn:
      case PhotoViewScaleState.covering:
        return widget.maxScale;
      case PhotoViewScaleState.zoomedOut:
        return widget.minScale;
      case PhotoViewScaleState.originalSize:
        return widget.initialScale;
    }
  }

  Offset _offsetForAnchor(Offset localPosition, double scale) {
    final double halfWidth = widget.size.width / 2;
    final double halfHeight = widget.size.height / 2;
    final double dx = (halfWidth - localPosition.dx) * scale;
    final double dy = (halfHeight - localPosition.dy) * scale;
    return Offset(dx, dy);
  }
}
