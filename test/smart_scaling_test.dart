import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/pages/read/layout/base/smart_scaling.dart';

void main() {
  group('vertical smart scaling', () {
    const Size viewport = Size(1000, 1000);

    test('fits an image whose extra height is below the threshold', () {
      final FittedSizes result = computeSmartScalingFittedSize(
        imageSize: const Size(1000, 1150),
        viewportSize: viewport,
        scrollAxis: Axis.vertical,
        thresholdPercent: 20,
      );

      expect(result.destination.height, 1000);
      expect(result.destination.width, closeTo(869.565, 0.001));
    });

    test('fits an image at the threshold boundary', () {
      final FittedSizes result = computeSmartScalingFittedSize(
        imageSize: const Size(1000, 1200),
        viewportSize: viewport,
        scrollAxis: Axis.vertical,
        thresholdPercent: 20,
      );

      expect(result.destination.height, 1000);
      expect(result.destination.width, closeTo(833.333, 0.001));
    });

    test('keeps a longer image width-fitted for adaptive page turning', () {
      final FittedSizes result = computeSmartScalingFittedSize(
        imageSize: const Size(1000, 1250),
        viewportSize: viewport,
        scrollAxis: Axis.vertical,
        thresholdPercent: 20,
      );

      expect(result.destination, const Size(1000, 1250));
    });

    test('honors a 100 percent threshold', () {
      final FittedSizes result = computeSmartScalingFittedSize(
        imageSize: const Size(1000, 1900),
        viewportSize: viewport,
        scrollAxis: Axis.vertical,
        thresholdPercent: 100,
      );

      expect(result.destination.height, 1000);
      expect(result.destination.width, closeTo(526.316, 0.001));
    });
  });

  test('horizontal smart scaling uses width as the overflow dimension', () {
    final FittedSizes result = computeSmartScalingFittedSize(
      imageSize: const Size(1150, 1000),
      viewportSize: const Size(1000, 1000),
      scrollAxis: Axis.horizontal,
      thresholdPercent: 20,
    );

    expect(result.destination.width, 1000);
    expect(result.destination.height, closeTo(869.565, 0.001));
  });

  group('adaptive turning after smart scaling', () {
    const Size viewport = Size(1000, 1000);

    test('turns to the exact image boundary for a fitted image', () {
      expect(
        shouldAdaptiveTurnByImage(
          visibleItemCount: 1,
          soleVisibleItemSize: viewport,
          viewportSize: viewport,
          scrollAxis: Axis.vertical,
          smartScalingEnabled: true,
        ),
        isTrue,
      );
    });

    test('continues turning by screen for a long image', () {
      expect(
        shouldAdaptiveTurnByImage(
          visibleItemCount: 1,
          soleVisibleItemSize: const Size(1000, 1250),
          viewportSize: viewport,
          scrollAxis: Axis.vertical,
          smartScalingEnabled: true,
        ),
        isFalse,
      );
    });

    test('preserves adaptive behavior when smart scaling is disabled', () {
      expect(
        shouldAdaptiveTurnByImage(
          visibleItemCount: 1,
          soleVisibleItemSize: viewport,
          viewportSize: viewport,
          scrollAxis: Axis.vertical,
          smartScalingEnabled: false,
        ),
        isFalse,
      );
    });

    test('turns by image whenever multiple images are visible', () {
      expect(
        shouldAdaptiveTurnByImage(
          visibleItemCount: 2,
          soleVisibleItemSize: null,
          viewportSize: viewport,
          scrollAxis: Axis.horizontal,
          smartScalingEnabled: true,
        ),
        isTrue,
      );
    });
  });
}
