import 'package:flutter/painting.dart';

/// Fits an image along the non-scrolling axis first. If the fitted image only
/// exceeds the viewport by [thresholdPercent] along the scrolling axis, it is
/// scaled down once more so the whole image is visible.
FittedSizes computeSmartScalingFittedSize({
  required Size imageSize,
  required Size viewportSize,
  required Axis scrollAxis,
  required int thresholdPercent,
}) {
  final Size axisFitSize = scrollAxis == Axis.vertical
      ? Size(viewportSize.width, double.infinity)
      : Size(double.infinity, viewportSize.height);
  final FittedSizes axisFitted = applyBoxFit(BoxFit.contain, imageSize, axisFitSize);
  final double fittedScrollExtent = scrollAxis == Axis.vertical
      ? axisFitted.destination.height
      : axisFitted.destination.width;
  final double viewportScrollExtent =
      scrollAxis == Axis.vertical ? viewportSize.height : viewportSize.width;
  final double maximumFitExtent =
      viewportScrollExtent * (1 + thresholdPercent.clamp(0, 100) / 100);

  if (fittedScrollExtent <= maximumFitExtent) {
    return applyBoxFit(BoxFit.contain, imageSize, viewportSize);
  }

  return axisFitted;
}

/// Chooses exact image-boundary turning when adaptive mode is showing either
/// multiple images or one smart-scaled image that now fits in the viewport.
/// Long images continue to turn by one screen at a time.
bool shouldAdaptiveTurnByImage({
  required int visibleItemCount,
  required Size? soleVisibleItemSize,
  required Size viewportSize,
  required Axis scrollAxis,
  required bool smartScalingEnabled,
}) {
  if (visibleItemCount > 1) {
    return true;
  }
  if (!smartScalingEnabled || visibleItemCount != 1 || soleVisibleItemSize == null) {
    return false;
  }

  const double extentTolerance = 0.5;
  final double itemExtent =
      scrollAxis == Axis.vertical ? soleVisibleItemSize.height : soleVisibleItemSize.width;
  final double viewportExtent =
      scrollAxis == Axis.vertical ? viewportSize.height : viewportSize.width;
  return itemExtent <= viewportExtent + extentTolerance;
}
