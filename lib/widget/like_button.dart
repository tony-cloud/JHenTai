import 'dart:async';

import 'package:flutter/material.dart';

/// A lightweight alternative to the old like_button package with optional
/// asynchronous tap and long-press callbacks.
///
/// Only the features required by the app are implemented: animated scaling,
/// custom icon builders, and async callbacks that resolve to the new liked
/// state. Additional behaviours from the original package (bubble effects,
/// counters, etc.) were intentionally omitted for simplicity.
class LikeButton extends StatefulWidget {
  const LikeButton({
    super.key,
    this.size = 40,
    this.isLiked,
    required this.likeBuilder,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.scaleFactor = 1.2,
    this.duration = const Duration(milliseconds: 220),
  }) : assert(scaleFactor >= 1);

  /// Visual size for hit test and layout.
  final double size;

  /// Optional external liked state. When provided, the button synchronises its
  /// internal state with this value on rebuilds.
  final bool? isLiked;

  /// Builds the child widget with the current liked state.
  final Widget Function(bool liked) likeBuilder;

  /// Async callback triggered on tap. Returning `true`/`false` updates the
  /// liked state. Returning `null` leaves the state unchanged.
  final Future<bool?> Function(bool isLiked)? onTap;

  /// Async callback triggered on long press. Uses the same contract as [onTap].
  final Future<bool?> Function(bool isLiked)? onLongPress;

  /// Controls whether the button reacts to gestures.
  final bool enabled;

  /// Maximum scale reached during the tap animation.
  final double scaleFactor;

  /// Duration of the scale animation.
  final Duration duration;

  @override
  State<LikeButton> createState() => _LikeButtonState();
}

class _LikeButtonState extends State<LikeButton> with SingleTickerProviderStateMixin {
  late bool _liked;
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  bool _handlingGesture = false;

  @override
  void initState() {
    super.initState();
    _liked = widget.isLiked ?? false;
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 1, end: widget.scaleFactor)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: widget.scaleFactor, end: 1)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 50,
      ),
    ]).animate(_controller);
  }

  @override
  void didUpdateWidget(covariant LikeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }

    if (widget.isLiked != null && widget.isLiked != _liked) {
      _liked = widget.isLiked!;
      // Trigger a subtle animation to reflect external state changes.
      _startAnimation();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _startAnimation() async {
    if (!mounted) {
      return;
    }
    try {
      await _controller.forward(from: 0);
    } finally {
      if (mounted) {
        _controller.stop();
      }
    }
  }

  void _handleTap() {
    _handleGesture(widget.onTap);
  }

  void _handleLongPress() {
    _handleGesture(widget.onLongPress);
  }

  void _handleGesture(Future<bool?> Function(bool isLiked)? callback) {
    if (!widget.enabled) {
      return;
    }
    if (callback == null) {
      _updateState(!_liked);
      return;
    }

    if (_handlingGesture) {
      return;
    }
    _handlingGesture = true;

    unawaited(Future(() async {
      bool? result;
      try {
        result = await callback(_liked);
      } finally {
        if (mounted) {
          setState(() {
            _handlingGesture = false;
          });
        } else {
          _handlingGesture = false;
        }
      }

      if (result != null) {
        _updateState(result);
      }
    }));
  }

  void _updateState(bool newValue) {
    if (!mounted || newValue == _liked) {
      return;
    }

    setState(() {
      _liked = newValue;
    });
    _startAnimation();
  }

  @override
  Widget build(BuildContext context) {
    final Widget child = SizedBox(
      height: widget.size,
      width: widget.size,
      child: Center(child: widget.likeBuilder(_liked)),
    );

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.enabled ? _handleTap : null,
      onLongPress: widget.enabled && widget.onLongPress != null ? _handleLongPress : null,
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, _) => Transform.scale(
          scale: _controller.isAnimating ? _scaleAnimation.value : 1,
          child: child,
        ),
      ),
    );
  }
}
