import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:animate_do/animate_do.dart';
import 'package:extended_image/extended_image.dart';
import 'package:get/get.dart';

import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/extension/widget_extension.dart';
import 'package:jhentai/model/gallery_image.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/setting/advanced_setting.dart';
import 'package:jhentai/setting/style_setting.dart';
import 'package:jhentai/utils/domain_fronting_util.dart';

typedef LoadingProgressWidgetBuilder = Widget Function(double);
typedef FailedWidgetBuilder = Widget Function(ExtendedImageState state);
typedef DownloadingWidgetBuilder = Widget Function();
typedef PausedWidgetBuilder = Widget Function();
typedef LoadingWidgetBuilder = Widget Function();
typedef CompletedWidgetBuilder = Widget? Function(ExtendedImageState state);

class EHImage extends StatelessWidget {
  final GalleryImage galleryImage;
  final bool autoLayout;
  final double? containerHeight;
  final double? containerWidth;
  final Color? containerColor;
  final BoxFit fit;
  final bool enableSlideOutPage;
  final BorderRadius borderRadius;
  final Object? heroTag;
  final bool clearMemoryCacheWhenDispose;
  final List<BoxShadow>? shadows;
  final bool forceFadeIn;
  final int? maxBytes;
  final Uint8List? memoryBytes;

  final LoadingProgressWidgetBuilder? loadingProgressWidgetBuilder;
  final FailedWidgetBuilder? failedWidgetBuilder;
  final DownloadingWidgetBuilder? downloadingWidgetBuilder;
  final PausedWidgetBuilder? pausedWidgetBuilder;
  final LoadingWidgetBuilder? loadingWidgetBuilder;
  final CompletedWidgetBuilder? completedWidgetBuilder;

  const EHImage({
    super.key,
    required this.galleryImage,
    this.autoLayout = false,
    this.containerHeight,
    this.containerWidth,
    this.containerColor,
    this.fit = BoxFit.contain,
    this.enableSlideOutPage = false,
    this.borderRadius = BorderRadius.zero,
    this.heroTag,
    this.clearMemoryCacheWhenDispose = false,
    this.shadows,
    this.forceFadeIn = false,
    this.maxBytes,
    this.memoryBytes,
    this.loadingProgressWidgetBuilder,
    this.failedWidgetBuilder,
    this.downloadingWidgetBuilder,
    this.pausedWidgetBuilder,
    this.loadingWidgetBuilder,
    this.completedWidgetBuilder,
  });

  const EHImage.autoLayout({
    super.key,
    required this.galleryImage,
    this.autoLayout = true,
    this.containerHeight,
    this.containerWidth,
    this.containerColor,
    this.fit = BoxFit.contain,
    this.enableSlideOutPage = false,
    this.borderRadius = BorderRadius.zero,
    this.heroTag,
    this.clearMemoryCacheWhenDispose = false,
    this.shadows,
    this.forceFadeIn = false,
    this.maxBytes,
    this.memoryBytes,
    this.loadingProgressWidgetBuilder,
    this.failedWidgetBuilder,
    this.downloadingWidgetBuilder,
    this.pausedWidgetBuilder,
    this.loadingWidgetBuilder,
    this.completedWidgetBuilder,
  });

  @override
  Widget build(BuildContext context) {
    Widget child = advancedSetting.inNoImageMode.isTrue
        ? const SizedBox()
        : galleryImage.path == null
            ? buildNetworkImage(context)
            : buildFileImage(context);

    if (heroTag != null && styleSetting.isInMobileLayout) {
      child = Hero(tag: heroTag!, child: child);
    }

    if (autoLayout) {
      return LayoutBuilder(
        builder: (_, constraints) => Container(
          height: constraints.maxHeight,
          width: constraints.maxWidth,
          decoration: BoxDecoration(color: containerColor, borderRadius: borderRadius),
          child: child,
        ),
      );
    }

    return Container(
      height: containerHeight,
      width: containerWidth,
      decoration: BoxDecoration(color: containerColor, borderRadius: borderRadius),
      child: child,
    );
  }

  Widget buildNetworkImage(BuildContext context) {
    final String rawUrl = _replaceEXUrl(galleryImage.url);
    final DomainFrontingResult fronting = DomainFrontingUtil.build(rawUrl);

    return ExtendedImage.network(
      fronting.url,
      fit: fit,
      height: containerHeight,
      width: containerWidth,
      headers: fronting.headers,
      handleLoadingProgress: loadingProgressWidgetBuilder != null,
      printError: kDebugMode,
      enableSlideOutPage: enableSlideOutPage,
      clearMemoryCacheWhenDispose: clearMemoryCacheWhenDispose,
      loadStateChanged: (ExtendedImageState state) {
        switch (state.extendedImageLoadState) {
          case LoadState.loading:
            return loadingProgressWidgetBuilder != null
                ? loadingProgressWidgetBuilder!
                    .call(_computeLoadingProgress(state.loadingProgress, state.extendedImageInfo))
                : Center(child: UIConfig.loadingAnimation(context));
          case LoadState.failed:
            DomainFrontingUtil.markUnavailableFromResult(fronting);
            return failedWidgetBuilder?.call(state) ??
                Center(
                  child: GestureDetector(
                      onTap: state.reLoadImage,
                      child: const Icon(Icons.sentiment_very_dissatisfied)),
                );
          case LoadState.completed:
            state.returnLoadStateChangedWidget = true;

            Widget child = completedWidgetBuilder?.call(state) ?? _buildExtendedRawImage(state);

            if (borderRadius != BorderRadius.zero) {
              child = ClipRRect(borderRadius: borderRadius, child: child);
            }

            if (state.slidePageState != null) {
              child = ExtendedImageSlidePageHandler(
                  extendedImageSlidePageState: state.slidePageState, child: child);
            }

            child = Center(
              child: Container(
                decoration: BoxDecoration(boxShadow: shadows, borderRadius: borderRadius),
                child: child,
              ),
            );

            return forceFadeIn || !state.wasSynchronouslyLoaded ? child.fadeInWidget() : child;
        }
      },
      maxBytes: maxBytes,
    );
  }

  Widget buildFileImage(BuildContext context) {
    if (memoryBytes != null) {
      return ExtendedImage.memory(
        memoryBytes!,
        fit: fit,
        height: containerHeight,
        width: containerWidth,
        enableLoadState: loadingWidgetBuilder != null ||
            failedWidgetBuilder != null ||
            completedWidgetBuilder != null,
        enableSlideOutPage: enableSlideOutPage,
        borderRadius: borderRadius,
        shape: BoxShape.rectangle,
        clearMemoryCacheWhenDispose: clearMemoryCacheWhenDispose,
        loadStateChanged: (ExtendedImageState state) {
          switch (state.extendedImageLoadState) {
            case LoadState.loading:
              return loadingWidgetBuilder != null
                  ? loadingWidgetBuilder!.call()
                  : Center(child: UIConfig.loadingAnimation(context));
            case LoadState.failed:
              return failedWidgetBuilder?.call(state) ??
                  Center(
                    child: GestureDetector(
                        onTap: state.reLoadImage,
                        child: const Icon(Icons.sentiment_very_dissatisfied)),
                  );
            case LoadState.completed:
              state.returnLoadStateChangedWidget = true;

              Widget child = completedWidgetBuilder?.call(state) ?? _buildExtendedRawImage(state);

              child = ClipRRect(borderRadius: borderRadius, child: child);

              if (state.slidePageState != null) {
                child = ExtendedImageSlidePageHandler(
                    extendedImageSlidePageState: state.slidePageState, child: child);
              }

              return FadeIn(
                child: Center(
                  child: Container(
                    decoration: BoxDecoration(boxShadow: shadows, borderRadius: borderRadius),
                    child: child,
                  ),
                ),
              );
          }
        },
        maxBytes: maxBytes,
        filterQuality: FilterQuality.medium,
      );
    }

    if (galleryImage.downloadStatus == DownloadStatus.paused) {
      return pausedWidgetBuilder?.call() ?? const Center(child: CircularProgressIndicator());
    }

    if (galleryImage.downloadStatus == DownloadStatus.downloading) {
      return downloadingWidgetBuilder?.call() ?? const Center(child: CircularProgressIndicator());
    }

    final String filePath = GalleryDownloadService.computeImageDownloadAbsolutePathFromRelativePath(
      galleryImage.path!,
    );
    final io.File imageFile = io.File(filePath);

    return ExtendedImage.file(
      imageFile,
      fit: fit,
      height: containerHeight,
      width: containerWidth,
      enableLoadState: loadingWidgetBuilder != null ||
          failedWidgetBuilder != null ||
          completedWidgetBuilder != null,
      enableSlideOutPage: enableSlideOutPage,
      borderRadius: borderRadius,
      shape: BoxShape.rectangle,
      clearMemoryCacheWhenDispose: clearMemoryCacheWhenDispose,
      loadStateChanged: (ExtendedImageState state) {
        switch (state.extendedImageLoadState) {
          case LoadState.loading:
            return loadingWidgetBuilder != null
                ? loadingWidgetBuilder!.call()
                : Center(child: UIConfig.loadingAnimation(context));
          case LoadState.failed:
            _logFileLoadFailure(imageFile, state);
            return failedWidgetBuilder?.call(state) ??
                Center(
                  child: GestureDetector(
                      onTap: state.reLoadImage,
                      child: const Icon(Icons.sentiment_very_dissatisfied)),
                );
          case LoadState.completed:
            state.returnLoadStateChangedWidget = true;

            Widget child = completedWidgetBuilder?.call(state) ?? _buildExtendedRawImage(state);

            child = ClipRRect(borderRadius: borderRadius, child: child);

            if (state.slidePageState != null) {
              child = ExtendedImageSlidePageHandler(
                  extendedImageSlidePageState: state.slidePageState, child: child);
            }

            return FadeIn(
              child: Center(
                child: Container(
                  decoration: BoxDecoration(boxShadow: shadows, borderRadius: borderRadius),
                  child: child,
                ),
              ),
            );
        }
      },
      maxBytes: maxBytes,
      filterQuality: FilterQuality.medium,
    );
  }

  double _computeLoadingProgress(ImageChunkEvent? loadingProgress, ImageInfo? extendedImageInfo) {
    if (loadingProgress == null) {
      return 0.01;
    }

    int cur = loadingProgress.cumulativeBytesLoaded;
    int? total = extendedImageInfo?.sizeBytes;
    int? compressed = loadingProgress.expectedTotalBytes;
    return cur / (compressed ?? total ?? cur * 100);
  }

  void _logFileLoadFailure(io.File file, ExtendedImageState state) {
    final bool exists = file.existsSync();
    int? length;

    if (exists) {
      try {
        length = file.lengthSync();
      } catch (e, stack) {
        log.error('Read downloaded image length failed: ${file.path}', e, stack);
      }
    }

    final String reason = !exists
        ? 'file_missing'
        : ((length ?? 0) == 0)
            ? 'empty_file'
            : 'decode_failed';

    log.error(
      'Load downloaded image failed ($reason): path=${file.path}, exists=$exists, length=${length ?? 'unknown'}, url=${galleryImage.url}, status=${galleryImage.downloadStatus}, exception=${state.lastException}',
    );
  }

  /// replace image host: exhentai.org -> ehgt.org
  String _replaceEXUrl(String url) {
    Uri rawUri = Uri.parse(url);
    String host = rawUri.host;
    if (host != 's.exhentai.org') {
      return url;
    }

    Uri newUri = rawUri.replace(host: 'ehgt.org');
    return newUri.toString();
  }

  Widget _buildExtendedRawImage(ExtendedImageState state) {
    FittedSizes fittedSizes = applyBoxFit(
      fit,
      Size(state.extendedImageInfo!.image.width.toDouble(),
          state.extendedImageInfo!.image.height.toDouble()),
      Size(containerWidth ?? double.infinity, containerHeight ?? double.infinity),
    );

    return ExtendedRawImage(
      image: state.extendedImageInfo?.image,
      height: fittedSizes.destination.height == 0 ? null : fittedSizes.destination.height,
      width: fittedSizes.destination.width == 0 ? null : fittedSizes.destination.width,
      scale: state.extendedImageInfo?.scale ?? 1.0,
      fit: fit,
    );
  }
}
