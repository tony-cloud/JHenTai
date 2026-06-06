import 'dart:io' as io;
import 'dart:math';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import 'package:jhentai/database/database.dart';
import 'package:jhentai/extension/get_logic_extension.dart';
import 'package:jhentai/model/gallery_image.dart';
import 'package:jhentai/model/read_page_info.dart';
import 'package:jhentai/setting/read_setting.dart';

import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/image_block_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/service/super_resolution_service.dart';
import 'package:jhentai/utils/convert_util.dart';
import 'package:jhentai/widget/eh_image.dart';
import 'package:jhentai/widget/icon_text_button.dart';
import 'package:jhentai/widget/loading_state_indicator.dart';
import 'package:jhentai/pages/read/read_page_logic.dart';
import 'package:jhentai/pages/read/read_page_state.dart';
import 'package:jhentai/pages/read/layout/base/base_layout_logic.dart';
import 'package:jhentai/utils/toast_util.dart';

abstract class BaseLayout extends StatelessWidget {
  BaseLayout({super.key});

  final ReadPageLogic readPageLogic = Get.find<ReadPageLogic>();
  final ReadPageState readPageState = Get.find<ReadPageLogic>().state;

  BaseLayoutLogic get logic;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
        future: logic.readPageLogic.delayInitCompleter.future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return GetBuilder<BaseLayoutLogic>(
              id: BaseLayoutLogic.pageId,
              global: false,
              init: logic,
              builder: (_) => ScrollConfiguration(
                behavior: readSetting.showScrollBar.isTrue
                    ? UIConfig.scrollBehaviourWithScrollBarWithMouse
                    : UIConfig.scrollBehaviourWithoutScrollBarWithMouse,
                child: buildBody(context),
              ),
            );
          }

          return Center(child: Container(color: UIConfig.readPageBackGroundColor));
        });
  }

  Widget buildBody(BuildContext context);

  /// online mode: parsing and loading automatically while scrolling
  Widget buildItemInOnlineMode(BuildContext context, int index) {
    return GetBuilder<ReadPageLogic>(
      id: '${readPageLogic.onlineImageId}::$index',
      builder: (_) {
        /// step 1: parse image href if needed. check if thumbnail's info exists, if not, [parse] one page of thumbnails to get image hrefs.
        if (readPageState.thumbnails[index] == null) {
          if (readPageState.parseImageHrefsStates[index] == LoadingState.idle) {
            readPageLogic.beginToParseImageHref(index);
          }
          return _buildParsingHrefsIndicator(context, index);
        }

        /// step 2: parse image url.
        if (readPageState.images[index] == null) {
          if (readPageState.parseImageUrlStates[index] == LoadingState.idle) {
            readPageLogic.beginToParseImageUrl(index, false);
          }
          return _buildParsingUrlIndicator(context, index);
        }

        /// step 3: use url to load image
        return _buildOnlineImage(context, index);
      },
    );
  }

  /// wait for [readPageLogic] to parse image href in online mode
  Widget _buildParsingHrefsIndicator(BuildContext context, int index) {
    Size placeHolderSize = logic.getPlaceHolderSize(index);

    return GestureDetector(
      onTap: () => readPageLogic.beginToParseImageHref(index),
      child: SizedBox(
        height: placeHolderSize.height,
        width: placeHolderSize.width,
        child: GetBuilder<ReadPageLogic>(
          id: '${readPageLogic.parseImageHrefsStateId}::$index',
          builder: (_) => Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              LoadingStateIndicator(
                loadingState: readPageState.parseImageHrefsStates[index],
                idleWidgetBuilder: () => const CircularProgressIndicator(),
                errorWidgetBuilder: () =>
                    const Icon(Icons.warning, color: UIConfig.readPageWarningButtonColor),
              ),
              Text(
                readPageState.parseImageHrefsStates[index] == LoadingState.error
                    ? readPageState.parseImageHrefErrorMsg!
                    : 'parsingPage'.tr,
              ).marginOnly(top: 8),
              Text((index + 1).toString()).marginOnly(top: 4),
            ],
          ),
        ),
      ),
    );
  }

  /// wait for [readPageLogic] to parse image url in online mode
  Widget _buildParsingUrlIndicator(BuildContext context, int index) {
    Size placeHolderSize = logic.getPlaceHolderSize(index);

    return GestureDetector(
      onTap: () => readPageLogic.beginToParseImageUrl(index, true),
      child: SizedBox(
        height: placeHolderSize.height,
        width: placeHolderSize.width,
        child: GetBuilder<ReadPageLogic>(
          id: '${readPageLogic.parseImageUrlStateId}::$index',
          builder: (_) => Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              LoadingStateIndicator(
                loadingState: readPageState.parseImageUrlStates[index],
                idleWidgetBuilder: () => const CircularProgressIndicator(),
                errorWidgetBuilder: () =>
                    const Icon(Icons.warning, color: UIConfig.readPageWarningButtonColor),
              ),
              Text(
                readPageState.parseImageUrlStates[index] == LoadingState.error
                    ? readPageState.parseImageUrlErrorMsg[index]!
                    : 'parsingURL'.tr,
              ).marginOnly(top: 8),
              Text((index + 1).toString()).marginOnly(top: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOnlineImage(BuildContext context, int index) {
    return Obx(() {
      imageBlockService.version.value;
      GalleryImage image = readPageState.images[index]!;
      String? key = imageBlockService.buildCacheKey(image);
      ImageBlockReason? reason =
          imageBlockService.shouldBlock(image.imageHash, fallbackKey: image.url);
      if (reason != null) {
        return _buildBlockedIndicator(
          context,
          reason,
          index,
          logic.getPlaceHolderSize(index),
          key,
        );
      }

      return GestureDetector(
        onLongPress: () => logic.showBottomMenuInOnlineMode(index, context),
        onSecondaryTap: () => logic.showBottomMenuInOnlineMode(index, context),
        child: EHImage(
          galleryImage: image,
          containerWidth: logic.readPageState.imageContainerSizes[index]?.width ??
              logic.getPlaceHolderSize(index).width,
          containerHeight: logic.readPageState.imageContainerSizes[index]?.height ??
              logic.getPlaceHolderSize(index).height,
          clearMemoryCacheWhenDispose: true,
          loadingProgressWidgetBuilder: (double progress) =>
              _loadingProgressWidgetBuilder(index, progress),
          failedWidgetBuilder: (ExtendedImageState state) => _failedWidgetBuilder(index, state),
          completedWidgetBuilder: (state) {
            _scheduleQrScanForOnline(image, index, state);
            return completedWidgetBuilderCallBack(index, state);
          },
          maxBytes: readSetting.enableMaxImageKilobyte.isTrue
              ? readSetting.maxImageKilobyte.toInt() * 1024
              : null,
        ),
      );
    });
  }

  /// loading for online mode
  Widget _loadingProgressWidgetBuilder(int index, double progress) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        CircularProgressIndicator(value: progress),
        Text('loading'.tr).marginOnly(top: 8),
        Text((index + 1).toString()).marginOnly(top: 4),
      ],
    );
  }

  /// failed for online mode
  Widget _failedWidgetBuilder(int index, ExtendedImageState state) {
    log.warning('online image widget build failed', state.lastException);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconTextButton(
          icon: const Icon(Icons.error, color: UIConfig.readPageButtonColor),
          text:
              Text('networkError'.tr, style: const TextStyle(color: UIConfig.readPageButtonColor)),
          onPressed: () => logic.readPageLogic.reloadImage(index),
        ),
        Text((index + 1).toString()),
      ],
    );
  }

  /// completed for online mode
  Widget? completedWidgetBuilderCallBack(int index, ExtendedImageState state) {
    if (state.extendedImageInfo == null || logic.readPageState.imageContainerSizes[index] != null) {
      return null;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (state.extendedImageInfo == null ||
          logic.readPageState.imageContainerSizes[index] != null) {
        return;
      }
      FittedSizes fittedSizes = logic.getImageFittedSize(
        Size(state.extendedImageInfo!.image.width.toDouble(),
            state.extendedImageInfo!.image.height.toDouble()),
      );
      logic.readPageState.imageContainerSizes[index] = fittedSizes.destination;
      logic.readPageLogic.updateSafely(['${readPageLogic.onlineImageId}::$index']);
    });

    return null;
  }

  /// local mode: wait for download service to parse and download
  Widget buildItemInLocalMode(BuildContext context, int index) {
    return GetBuilder<GalleryDownloadService>(
      id: '${galleryDownloadService.downloadImageId}::${readPageState.readPageInfo.gid}::$index',
      builder: (_) {
        /// step 1: wait for parsing image's href for this image. But if image's url has been parsed,
        /// we don't need to wait parsing thumbnail.
        if (readPageState.thumbnails[index] == null && readPageState.images[index] == null) {
          return _buildWaitParsingHrefsIndicator(context, index);
        }

        /// step 2: wait for parsing image's url.
        if (readPageState.images[index] == null) {
          return _buildWaitParsingUrlIndicator(context, index);
        }

        /// step 3: check if we are using super resolution
        if (logic.readPageState.useSuperResolution) {
          return _buildLocalSuperResolutionImage(context, index);
        }

        /// step 4: wait for downloading or display it
        return _buildLocalImage(context, index);
      },
    );
  }

  Widget _buildLocalSuperResolutionImage(BuildContext context, int index) {
    return GetBuilder<SuperResolutionService>(
      id: '${SuperResolutionService.superResolutionImageId}::${readPageState.readPageInfo.gid!}::$index',
      builder: (_) {
        int gid = readPageState.readPageInfo.gid!;
        SuperResolutionType type = readPageState.readPageInfo.mode == ReadMode.downloaded
            ? SuperResolutionType.gallery
            : SuperResolutionType.archive;
        if (superResolutionService.get(gid, type)?.imageStatuses[index] !=
            SuperResolutionStatus.success) {
          return _buildLocalImage(context, index);
        }

        return Obx(() {
          imageBlockService.version.value;
          GalleryImage image = readPageState.images[index]!.copyWith(
            path: superResolutionService
                .computeImageOutputRelativePath(readPageState.images[index]!.path!),
          );
          String? key = imageBlockService.buildCacheKey(image);

          ImageBlockReason? reason = imageBlockService.shouldBlock(
            image.imageHash,
            fallbackKey: image.path ?? image.url,
          );
          if (reason != null) {
            return _buildBlockedIndicator(
              context,
              reason,
              index,
              logic.getPlaceHolderSize(index),
              key,
            );
          }

          return GestureDetector(
            onLongPress: () => logic.showBottomMenuInLocalMode(index, context),
            onSecondaryTap: () => logic.showBottomMenuInLocalMode(index, context),
            child: EHImage(
              galleryImage: image,
              containerWidth: logic.readPageState.imageContainerSizes[index]?.width ??
                  logic.getPlaceHolderSize(index).width,
              containerHeight: logic.readPageState.imageContainerSizes[index]?.height ??
                  logic.getPlaceHolderSize(index).height,
              clearMemoryCacheWhenDispose: true,
              loadingWidgetBuilder: () => _loadingWidgetBuilder(context, index),
              failedWidgetBuilder: (state) => _failedWidgetBuilderForLocalMode(index, state),
              completedWidgetBuilder: (state) {
                _scheduleQrScanForLocal(image, index, null, state);
                return completedWidgetBuilderForLocalModeCallBack(index, state);
              },
              maxBytes: readSetting.enableMaxImageKilobyte.isTrue
                  ? readSetting.maxImageKilobyte.toInt() * 1024
                  : null,
            ),
          );
        });
      },
    );
  }

  /// wait for [GalleryDownloadService] to parse image href in local mode
  Widget _buildWaitParsingHrefsIndicator(BuildContext context, int index) {
    DownloadStatus downloadStatus = galleryDownloadService
        .galleryDownloadInfos[readPageState.readPageInfo.gid]!.downloadProgress.downloadStatus;
    Size placeHolderSize = logic.getPlaceHolderSize(index);

    return SizedBox(
      height: placeHolderSize.height,
      width: placeHolderSize.width,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (downloadStatus == DownloadStatus.downloading) const CircularProgressIndicator(),
          if (downloadStatus == DownloadStatus.paused)
            const Icon(Icons.pause_circle_outline, color: UIConfig.readPageButtonColor),
          Text(downloadStatus == DownloadStatus.downloading ? 'parsingPage'.tr : 'paused'.tr)
              .marginOnly(top: 8),
          Text((index + 1).toString()).marginOnly(top: 4),
        ],
      ),
    );
  }

  /// wait for [GalleryDownloadService] to parse image url in local mode
  Widget _buildWaitParsingUrlIndicator(BuildContext context, int index) {
    DownloadStatus downloadStatus = galleryDownloadService
        .galleryDownloadInfos[readPageState.readPageInfo.gid]!.downloadProgress.downloadStatus;
    Size placeHolderSize = logic.getPlaceHolderSize(index);
    return SizedBox(
      height: placeHolderSize.height,
      width: placeHolderSize.width,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (downloadStatus == DownloadStatus.downloading) const CircularProgressIndicator(),
          if (downloadStatus == DownloadStatus.paused)
            const Icon(Icons.pause_circle_outline, color: UIConfig.readPageButtonColor),
          Text(downloadStatus == DownloadStatus.downloading ? 'parsingURL'.tr : 'paused'.tr)
              .marginOnly(top: 8),
          Text((index + 1).toString()).marginOnly(top: 4),
        ],
      ),
    );
  }

  Widget _buildLocalImage(BuildContext context, int index) {
    final memoryBytes = readPageLogic.getLocalMemoryImage(index);
    final bool keepMemoryCache = readPageLogic.shouldKeepLocalMemoryCache(index);

    return Obx(() {
      imageBlockService.version.value;
      GalleryImage image = readPageState.images[index]!;
      if (image.downloadStatus == DownloadStatus.downloadFailed) {
        return _buildDownloadFailedIndicator(index, logic.getPlaceHolderSize(index));
      }
      String? key = imageBlockService.buildCacheKey(image);
      ImageBlockReason? reason = imageBlockService.shouldBlock(
        image.imageHash,
        fallbackKey: image.path ?? image.url,
      );
      if (!kIsWeb && image.path != null) {
        final String absolutePath =
            GalleryDownloadService.computeImageDownloadAbsolutePathFromRelativePath(image.path!);
        if (!io.File(absolutePath).existsSync()) {
          return _buildBlockedIndicator(
            context,
            reason ?? ImageBlockReason.builtInHash,
            index,
            logic.getPlaceHolderSize(index),
            key,
          );
        }
      }
      if (reason != null) {
        return _buildBlockedIndicator(
          context,
          reason,
          index,
          logic.getPlaceHolderSize(index),
          key,
        );
      }

      return GestureDetector(
        onLongPress: () => logic.showBottomMenuInLocalMode(index, context),
        onSecondaryTap: () => logic.showBottomMenuInLocalMode(index, context),
        child: EHImage(
          galleryImage: image,
          containerWidth: logic.readPageState.imageContainerSizes[index]?.width ??
              logic.getPlaceHolderSize(index).width,
          containerHeight: logic.readPageState.imageContainerSizes[index]?.height ??
              logic.getPlaceHolderSize(index).height,
          memoryBytes: memoryBytes,
          clearMemoryCacheWhenDispose: !keepMemoryCache,
          downloadingWidgetBuilder: () => _downloadingWidgetBuilder(index),
          pausedWidgetBuilder: () => _pausedWidgetBuilder(index),
          loadingWidgetBuilder: () => _loadingWidgetBuilder(context, index),
          failedWidgetBuilder: (state) => _failedWidgetBuilderForLocalMode(index, state),
          completedWidgetBuilder: (state) {
            _scheduleQrScanForLocal(image, index, memoryBytes, state);
            return completedWidgetBuilderForLocalModeCallBack(index, state);
          },
          maxBytes: readSetting.enableMaxImageKilobyte.isTrue
              ? readSetting.maxImageKilobyte.toInt() * 1024
              : null,
        ),
      );
    });
  }

  Widget _buildDownloadFailedIndicator(int index, Size placeHolderSize) {
    final int? gid = readPageState.readPageInfo.gid;

    return SizedBox(
      height: placeHolderSize.height,
      width: placeHolderSize.width,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: UIConfig.readPageWarningButtonColor),
          Text('downloadFailed'.tr).marginOnly(top: 8),
          TextButton(
            onPressed:
                gid == null ? null : () => galleryDownloadService.reDownloadImage(gid, index),
            child: Text('reDownload'.tr),
          ),
          Text((index + 1).toString()).marginOnly(top: 4),
        ],
      ),
    );
  }

  /// downloading for local mode
  Widget _downloadingWidgetBuilder(int index) {
    return GetBuilder<GalleryDownloadService>(
      id: '${galleryDownloadService.galleryDownloadSpeedComputerId}::${readPageState.readPageInfo.gid}',
      builder: (_) {
        GalleryDownloadSpeedComputer speedComputer = galleryDownloadService
            .galleryDownloadInfos[readPageState.readPageInfo.gid]!.speedComputer;
        int downloadedBytes = speedComputer.imageDownloadedBytes[index];
        int totalBytes = speedComputer.imageTotalBytes[index];

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(value: max(downloadedBytes / totalBytes, 0.01)),
            Text('downloading'.tr).marginOnly(top: 8),
            Text((index + 1).toString()),
          ],
        );
      },
    );
  }

  /// paused for local mode
  Widget _pausedWidgetBuilder(int index) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.pause_circle_outline, color: UIConfig.readPageButtonColor),
        Text('paused'.tr).marginOnly(top: 8),
        Text((index + 1).toString()),
      ],
    );
  }

  /// loading for local mode
  Widget _loadingWidgetBuilder(BuildContext context, int index) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        UIConfig.loadingAnimation(context),
        Text((index + 1).toString()),
      ],
    );
  }

  /// failed for local mode
  Widget _failedWidgetBuilderForLocalMode(int index, ExtendedImageState state) {
    log.warning('local image widget build failed', state.lastException);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconTextButton(
          icon: const Icon(Icons.sentiment_very_dissatisfied),
          text: Text('error'.tr, style: const TextStyle(color: UIConfig.readPageButtonColor)),
          onPressed: state.reLoadImage,
        ),
        Text((index + 1).toString()),
      ],
    );
  }

  /// completed for local mode
  Widget? completedWidgetBuilderForLocalModeCallBack(int index, ExtendedImageState state) {
    if (state.extendedImageInfo == null || logic.readPageState.imageContainerSizes[index] != null) {
      return null;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (state.extendedImageInfo == null ||
          logic.readPageState.imageContainerSizes[index] != null) {
        return;
      }
      FittedSizes fittedSizes = logic.getImageFittedSize(
        Size(state.extendedImageInfo!.image.width.toDouble(),
            state.extendedImageInfo!.image.height.toDouble()),
      );
      logic.readPageState.imageContainerSizes[index] = fittedSizes.destination;
      galleryDownloadService.updateSafely(
          ['${galleryDownloadService.downloadImageId}::${readPageState.readPageInfo.gid}::$index']);
    });

    return null;
  }

  Widget _buildBlockedIndicator(
    BuildContext context,
    ImageBlockReason reason,
    int index,
    Size placeHolderSize,
    String? key,
  ) {
    if (imageBlockService.blockedImageHandling.value == BlockedImageHandling.hide) {
      return const SizedBox.shrink();
    }

    String reasonText;
    switch (reason) {
      case ImageBlockReason.hash:
        reasonText = 'blockedImageReasonHash'.tr;
        break;
      case ImageBlockReason.builtInHash:
        reasonText = 'blockedImageReasonBuiltIn'.tr;
        break;
      case ImageBlockReason.qrCode:
        reasonText = 'blockedImageReasonQr'.tr;
        break;
    }

    return GestureDetector(
      onLongPress: () => _showBlockedMenu(context, reason, key),
      child: Container(
        alignment: Alignment.center,
        height: placeHolderSize.height,
        width: placeHolderSize.width,
        color: UIConfig.readPageBackGroundColor,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.remove_circle_outline, color: UIConfig.readPageWarningButtonColor),
            Text('blockedImageMessage'.tr),
            Text(reasonText).marginOnly(top: 4),
            Text((index + 1).toString()).marginOnly(top: 4),
          ],
        ),
      ),
    );
  }

  void _showBlockedMenu(BuildContext context, ImageBlockReason reason, String? key) {
    if (reason != ImageBlockReason.hash || key == null) {
      return;
    }

    showCupertinoModalPopup<void>(
      context: context,
      builder: (_) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(context).pop();
              _removeUserBlockedHash(key);
            },
            isDestructiveAction: true,
            child: Text('unblockImage'.tr),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(context).pop();
              Clipboard.setData(ClipboardData(text: key));
              toast('hasCopiedToClipboard'.tr);
            },
            child: Text('copyHash'.tr),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('cancel'.tr),
        ),
      ),
    );
  }

  void _removeUserBlockedHash(String key) {
    imageBlockService.removeUserBlockedHash(key).then((_) {
      toast('unblockImageSuccess'.tr);
    });
  }

  void _scheduleQrScanForOnline(
    GalleryImage image,
    int index,
    ExtendedImageState state,
  ) {
    if (imageBlockService.enableQrBlocking.isFalse) {
      return;
    }

    final String? cacheKey = imageBlockService.buildCacheKey(image);
    final QrBlockMode mode = imageBlockService.qrBlockMode.value;

    if (logic.isQrBlockRangeResolvedForIndex(index: index, mode: mode)) {
      if (cacheKey != null) {
        imageBlockService.addQrBlockedKeys(<String>[cacheKey]);
        logic.readPageLogic.updateSafely(['${readPageLogic.onlineImageId}::$index']);
      }
      return;
    }

    if (imageBlockService.shouldScanQrForIndex(index,
            totalImages: readPageState.readPageInfo.pageCount) ==
        false) {
      return;
    }

    imageBlockService
        .scanQrIfNeeded(
      imageHash: image.imageHash,
      fallbackKey: image.url,
      bytesLoader: () async {
        if (state.extendedImageInfo != null) {
          return state.extendedImageInfo!.image;
        }

        return null;
      },
      galleryTags: _getGalleryTagsForQr(),
    )
        .then((blocked) {
      if (blocked) {
        logic.registerQrDetection(index, mode);
      }

      final List<String> extraKeys = <String>[];
      if (blocked) {
        extraKeys.addAll(
          logic.collectRangeKeysAfterDetection(
            mode: mode,
            images: readPageState.images,
          ),
        );
      }

      extraKeys.addAll(
        logic.collectRangeKeysForIndex(
          index: index,
          key: cacheKey,
          mode: mode,
        ),
      );

      if (extraKeys.isNotEmpty) {
        imageBlockService.addQrBlockedKeys(extraKeys);
      }

      if (blocked) {
        logic.readPageLogic.updateSafely(['${readPageLogic.onlineImageId}::$index']);
      }
    });
  }

  void _scheduleQrScanForLocal(
    GalleryImage image,
    int index,
    Uint8List? memoryBytes,
    ExtendedImageState state,
  ) {
    if (imageBlockService.enableQrBlocking.isFalse) {
      return;
    }

    final String? cacheKey = imageBlockService.buildCacheKey(image);
    final QrBlockMode mode = imageBlockService.qrBlockMode.value;

    if (logic.isQrBlockRangeResolvedForIndex(index: index, mode: mode)) {
      if (cacheKey != null) {
        imageBlockService.addQrBlockedKeys(<String>[cacheKey]);
        galleryDownloadService.updateSafely([
          '${galleryDownloadService.downloadImageId}::${readPageState.readPageInfo.gid}::$index'
        ]);
      }
      return;
    }

    if (imageBlockService.shouldScanQrForIndex(index,
            totalImages: readPageState.readPageInfo.pageCount) ==
        false) {
      return;
    }

    imageBlockService
        .scanQrIfNeeded(
      imageHash: image.imageHash,
      fallbackKey: image.path ?? image.url,
      bytesLoader: () async {
        if (memoryBytes != null && memoryBytes.isNotEmpty) {
          return memoryBytes;
        }

        if (state.extendedImageInfo != null) {
          return state.extendedImageInfo!.image;
        }

        String? path = image.path;
        if (!kIsWeb && path != null) {
          String absolutePath =
              GalleryDownloadService.computeImageDownloadAbsolutePathFromRelativePath(path);
          try {
            return await io.File(absolutePath).readAsBytes();
          } on io.FileSystemException catch (e, stack) {
            log.error('Failed to read local image for qr scan: $absolutePath', e, stack);
          }
        }

        return null;
      },
      galleryTags: _getGalleryTagsForQr(),
    )
        .then((blocked) {
      if (blocked) {
        logic.registerQrDetection(index, mode);
      }

      final List<String> extraKeys = <String>[];
      if (blocked) {
        extraKeys.addAll(
          logic.collectRangeKeysAfterDetection(
            mode: mode,
            images: readPageState.images,
          ),
        );
      }

      extraKeys.addAll(
        logic.collectRangeKeysForIndex(
          index: index,
          key: cacheKey,
          mode: mode,
        ),
      );

      if (extraKeys.isNotEmpty) {
        imageBlockService.addQrBlockedKeys(extraKeys);
      }

      if (blocked) {
        galleryDownloadService.updateSafely([
          '${galleryDownloadService.downloadImageId}::${readPageState.readPageInfo.gid}::$index'
        ]);
      }
    });
  }

  List<TagData>? _getGalleryTagsForQr() {
    if (imageBlockService.enableQrBlockingForTags.isFalse) {
      return null;
    }

    int? gid = readPageState.readPageInfo.gid;
    if (gid == null) {
      return null;
    }

    GalleryDownloadedData? gallery =
        galleryDownloadService.gallerys.firstWhereOrNull((g) => g.gid == gid);
    if (gallery == null) {
      return null;
    }

    return tagDataString2TagDataList(gallery.tags);
  }
}
