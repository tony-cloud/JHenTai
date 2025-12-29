import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

import 'package:jhentai/widget/photo_view/j_photo_view.dart';

typedef JPhotoViewGalleryBuilder = JPhotoViewGalleryPageOptions Function(
  BuildContext context,
  int index,
);
typedef JPhotoViewGalleryPageChangedCallback = void Function(int index);

class JPhotoViewGallery extends StatefulWidget {
  const JPhotoViewGallery.builder({
    super.key,
    required this.itemCount,
    required this.builder,
    this.pageController,
    this.scrollPhysics,
    this.scrollDirection = Axis.horizontal,
    this.reverse = false,
    this.allowImplicitScrolling = false,
    this.onPageChanged,
    this.backgroundDecoration,
    this.wantKeepAlive = false,
  });

  final int itemCount;
  final JPhotoViewGalleryBuilder builder;
  final PageController? pageController;
  final ScrollPhysics? scrollPhysics;
  final Axis scrollDirection;
  final bool reverse;
  final bool allowImplicitScrolling;
  final JPhotoViewGalleryPageChangedCallback? onPageChanged;
  final BoxDecoration? backgroundDecoration;
  final bool wantKeepAlive;

  @override
  State<JPhotoViewGallery> createState() => _JPhotoViewGalleryState();
}

class _JPhotoViewGalleryState extends State<JPhotoViewGallery> {
  late PageController _controller;
  late bool _ownsController;

  @override
  void initState() {
    super.initState();
    _resetController();
  }

  @override
  void didUpdateWidget(JPhotoViewGallery oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageController != widget.pageController) {
      if (_ownsController) {
        _controller.dispose();
      }
      _resetController();
    }
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  void _resetController() {
    _ownsController = widget.pageController == null;
    _controller = widget.pageController ?? PageController();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: widget.backgroundDecoration ?? const BoxDecoration(color: Colors.black),
      child: PageView.builder(
        controller: _controller,
        scrollDirection: widget.scrollDirection,
        physics: widget.scrollPhysics,
        reverse: widget.reverse,
        itemCount: widget.itemCount,
        onPageChanged: widget.onPageChanged,
        allowImplicitScrolling: widget.allowImplicitScrolling,
        itemBuilder: (context, index) {
          final JPhotoViewGalleryPageOptions options = widget.builder(context, index);
          if (options.child == null) {
            return const SizedBox.shrink();
          }

          return JPhotoView(
            childSize: options.childSize,
            backgroundDecoration: options.backgroundDecoration,
            wantKeepAlive: widget.wantKeepAlive,
            controller: options.controller,
            scaleStateController: options.scaleStateController,
            minScale: options.minScale,
            maxScale: options.maxScale,
            initialScale: options.initialScale,
            scaleStateCycle: options.scaleStateCycle,
            enableTapDragZoom: options.enableTapDragZoom,
            basePosition: options.basePosition,
            tightMode: options.tightMode,
            filterQuality: options.filterQuality,
            enableRotation: options.enableRotation,
            onTapUp: options.onTapUp,
            onTapDown: options.onTapDown,
            onScaleEnd: options.onScaleEnd,
            onDoubleTapZoomEnd: options.onDoubleTapZoomEnd,
            child: options.child,
          );
        },
      ),
    );
  }
}

class JPhotoViewGalleryPageOptions {
  JPhotoViewGalleryPageOptions.customChild({
    required this.child,
    this.childSize,
    this.backgroundDecoration,
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
}
