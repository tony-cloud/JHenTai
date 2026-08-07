import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:clipboard/clipboard.dart';
import 'package:dio/dio.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_instance/get_instance.dart';
import 'package:get/get_rx/get_rx.dart';
import 'package:get/get_state_manager/get_state_manager.dart';
import 'package:get/get_utils/get_utils.dart';
import 'package:jhentai/extension/get_logic_extension.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/image_block_service.dart';
import 'package:jhentai/setting/download_setting.dart';
import 'package:jhentai/setting/user_setting.dart';
import 'package:jhentai/utils/permission_util.dart';
import 'package:jhentai/utils/string_uril.dart';
import 'package:jhentai/utils/toast_util.dart';
import 'package:path/path.dart';
import 'package:photo_view/photo_view.dart';
import 'package:saver_gallery/saver_gallery.dart';
import 'package:share_plus/share_plus.dart';
import 'package:jhentai/exception/eh_image_exception.dart';
import 'package:jhentai/model/gallery_image.dart';
import 'package:jhentai/setting/read_setting.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/utils/route_util.dart';
import 'package:jhentai/utils/screen_size_util.dart';
import 'package:jhentai/pages/read/read_page_logic.dart';
import 'package:jhentai/pages/read/read_page_state.dart';
import 'package:jhentai/pages/read/layout/base/smart_scaling.dart';

abstract class BaseLayoutLogic extends GetxController with GetTickerProviderStateMixin {
  static const String pageId = 'pageId';

  final ReadPageLogic readPageLogic = Get.find<ReadPageLogic>();
  final ReadPageState readPageState = Get.find<ReadPageLogic>().state;

  int? qrFirstDetectedIndex;
  int? qrLastDetectedIndex;
  int? qrSuperModeStartIndex;

  Timer? autoModeTimer;
  Worker? doubleTapGestureSwitcherListener;
  Worker? tapDragGestureSwitcherListener;
  Worker? showScrollBarListener;

  @override
  void onInit() {
    doubleTapGestureSwitcherListener =
        ever(readSetting.enableDoubleTapToScaleUp, (value) => updateSafely([pageId]));
    tapDragGestureSwitcherListener =
        ever(readSetting.enableTapDragToScaleUp, (value) => updateSafely([pageId]));
    showScrollBarListener = ever(readSetting.showScrollBar, (value) => updateSafely([pageId]));
    super.onInit();
  }

  @override
  void onClose() {
    autoModeTimer?.cancel();
    doubleTapGestureSwitcherListener?.dispose();
    tapDragGestureSwitcherListener?.dispose();
    showScrollBarListener?.dispose();
    super.onClose();
  }

  /// Tap left region or click right arrow key. If read direction is right-to-left, we should call [toNext], otherwise [toPrev]
  void toLeft();

  /// Tap right region or click right arrow key. If read direction is right-to-left, we should call [toPrev], otherwise [toNext]
  void toRight();

  /// to prev image or screen
  void toPrev();

  /// to next image or screen
  void toNext();

  void toImageIndex(int imageIndex) {
    if (readSetting.enablePageTurnAnime.isFalse) {
      jump2ImageIndex(imageIndex);
    } else {
      scroll2ImageIndex(imageIndex);
    }
  }

  @mustCallSuper
  void scroll2ImageIndex(int imageIndex, [Duration? duration]) {
    readPageLogic.update([readPageLogic.sliderId]);
  }

  @mustCallSuper
  void jump2ImageIndex(int imageIndex) {
    readPageLogic.syncThumbnails(imageIndex);
    readPageLogic.update([readPageLogic.sliderId]);
  }

  PhotoViewScaleState scaleStateCycle(PhotoViewScaleState actual) {
    switch (actual) {
      case PhotoViewScaleState.initial:
        return PhotoViewScaleState.zoomedIn;
      default:
        return PhotoViewScaleState.initial;
    }
  }

  void toggleDisplayFirstPageAlone() {}

  void enterAutoMode();

  @mustCallSuper
  void closeAutoMode() {
    autoModeTimer?.cancel();
  }

  void onPointerScroll(PointerScrollEvent value) {
    if (value.scrollDelta.dy > 0) {
      toNext();
    } else if (value.scrollDelta.dy < 0) {
      toPrev();
    }
  }

  void showBottomMenuInOnlineMode(int index, BuildContext context) {
    showCupertinoModalPopup(
      context: context,
      builder: (_) => CupertinoActionSheet(
        actions: <CupertinoActionSheetAction>[
          CupertinoActionSheetAction(
            child: Text('reload'.tr),
            onPressed: () {
              backRoute();
              readPageLogic.reloadImage(index);
            },
          ),
          CupertinoActionSheetAction(
            child: Text('share'.tr),
            onPressed: () async {
              backRoute();
              shareOnlineImage(index);
            },
          ),
          CupertinoActionSheetAction(
            child: Text('${'saveToGallery'.tr}(${'resampleImage'.tr})'),
            onPressed: () async {
              backRoute();
              saveOnlineImage(index);
            },
          ),
          CupertinoActionSheetAction(
            child: Text('blockThisImage'.tr),
            onPressed: () async {
              backRoute();
              await blockImageByHash(index, isLocal: false);
            },
          ),
          if (readPageState.images[index]!.originalImageUrl != null && userSetting.hasLoggedIn())
            CupertinoActionSheetAction(
              child: Text('${'saveToGallery'.tr}(${'originalImage'.tr})'),
              onPressed: () async {
                backRoute();
                saveOriginalOnlineImage(index);
              },
            ),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: backRoute, child: Text('cancel'.tr)),
      ),
    );
  }

  void showBottomMenuInLocalMode(int index, BuildContext context) {
    final GalleryImage? image =
        galleryDownloadService.galleryDownloadInfos[readPageState.readPageInfo.gid]?.images[index];

    if (image?.downloadStatus != DownloadStatus.downloaded) {
      return;
    }

    final bool hasLocalPath = image?.path != null;

    showCupertinoModalPopup(
      context: context,
      builder: (_) => CupertinoActionSheet(
        actions: <CupertinoActionSheetAction>[
          CupertinoActionSheetAction(
            child: Text('share'.tr),
            onPressed: () {
              backRoute();
              hasLocalPath ? shareLocalImage(index) : shareOnlineImage(index);
            },
          ),
          CupertinoActionSheetAction(
            child: Text('saveToGallery'.tr),
            onPressed: () {
              backRoute();
              hasLocalPath ? saveLocalImage(index) : saveOnlineImage(index);
            },
          ),
          CupertinoActionSheetAction(
            child: Text('blockThisImage'.tr),
            onPressed: () async {
              backRoute();
              await blockImageByHash(index, isLocal: true);
            },
          ),
          if (hasLocalPath)
            CupertinoActionSheetAction(
              child: Text('reDownload'.tr),
              onPressed: () {
                backRoute();
                galleryDownloadService.reDownloadImage(readPageState.readPageInfo.gid!, index);
              },
            ),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: backRoute, child: Text('cancel'.tr)),
      ),
    );
  }

  void shareOnlineImage(int index) async {
    if (readPageState.images[index] == null) {
      return;
    }

    if (GetPlatform.isDesktop) {
      await FlutterClipboard.copy(readPageState.images[index]!.url);
      toast('hasCopiedToClipboard'.tr);
      return;
    }

    Uint8List? data = await getNetworkImageData(readPageState.images[index]!.url);
    if (data == null) {
      return;
    }

    // deal with .webp/.jpg which has not basename
    String ext = extension(readPageState.images[index]!.url);
    if (isEmptyOrNull(ext)) {
      ext = basename(readPageState.images[index]!.url);
    }

    String fileName =
        '${readPageState.readPageInfo.gid!}_${readPageState.readPageInfo.token!}_$index$ext';

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(data)],
        sharePositionOrigin:
            Rect.fromLTWH(0, 0, fullScreenWidth, readPageState.displayRegionSize.height * 2 / 3),
        fileNameOverrides: [fileName],
      ),
    );
  }

  void shareLocalImage(int index) {
    if (readPageState.images[index]?.path == null) {
      shareOnlineImage(index);
      return;
    }

    if (GetPlatform.isDesktop) {
      FlutterClipboard.copy(readPageState.images[index]!.url)
          .then((_) => toast('hasCopiedToClipboard'.tr));
      return;
    }

    SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            GalleryDownloadService.computeImageDownloadAbsolutePathFromRelativePath(
              galleryDownloadService
                  .galleryDownloadInfos[readPageState.readPageInfo.gid!]!.images[index]!.path!,
            ),
          )
        ],
        sharePositionOrigin:
            Rect.fromLTWH(0, 0, fullScreenWidth, readPageState.displayRegionSize.height * 2 / 3),
      ),
    );
  }

  Future<void> saveOnlineImage(int index) async {
    if (readPageState.images[index] == null) {
      return;
    }

    Uint8List? data = await getNetworkImageData(readPageState.images[index]!.url);
    if (data == null) {
      return;
    }

    // deal with .webp/.jpg which has not basename
    String ext = extension(readPageState.images[index]!.url);
    if (isEmptyOrNull(ext)) {
      ext = basename(readPageState.images[index]!.url);
    }

    String fileName =
        '${readPageState.readPageInfo.gid!}_${readPageState.readPageInfo.token!}_$index$ext';

    if (GetPlatform.isDesktop) {
      File file = File(join(downloadSetting.singleImageSavePath.value, fileName));
      try {
        await file.create(recursive: true);
        await file.writeAsBytes(data);
        toast('saveSuccess'.tr);
      } catch (e) {
        log.error('Save online image failed: $e');
        toast('saveFailed'.tr);
        file.delete().ignore();
        return;
      }
    } else {
      File file = File(join(downloadSetting.tempDownloadPath.value, fileName));
      try {
        await file.create(recursive: true);
        await file.writeAsBytes(data);
        bool success = await _saveFile2Album(file.path, fileName);
        toast(success ? 'saveSuccess'.tr : 'saveFailed'.tr);
      } catch (e) {
        log.error('Save online image failed: $e');
        toast('saveFailed'.tr);
        file.delete().ignore();
        return;
      }
    }
  }

  Future<void> saveOriginalOnlineImage(int index) async {
    if (readPageState.images[index] == null) {
      return;
    }

    if (readPageState.images[index]!.originalImageUrl == null || !userSetting.hasLoggedIn()) {
      return saveOnlineImage(index);
    }

    // deal with .webp/.jpg which has not basename
    String ext = extension(readPageState.images[index]!.originalImageUrl!);
    if (isEmptyOrNull(ext)) {
      ext = basename(readPageState.images[index]!.originalImageUrl!);
    }

    String fileName =
        '${readPageState.readPageInfo.gid!}_${readPageState.readPageInfo.token!}_${index}_original$ext';
    String downloadPath = join(downloadSetting.tempDownloadPath.value, fileName);
    File file = File(downloadPath);

    toast('downloading'.tr);
    Response response = await ehRequest.download(
        url: readPageState.images[index]!.originalImageUrl!, path: downloadPath);

    /// what we downloaded is not an image
    if (!response.isRedirect &&
        (response.headers[Headers.contentTypeHeader]?.contains("text/html; charset=UTF-8") ??
            false)) {
      File file = File(downloadPath);
      String data = file.readAsStringSync();
      file.delete().ignore();

      EHImageException? exception = GalleryDownloadService.imageData2Exception(data);
      log.error(
          'Save ${readPageState.readPageInfo.galleryTitle} image: $index failed, invalid reason: $exception');

      if (exception != null) {
        if (exception.operation == EHImageExceptionAfterOperation.pause) {
          toast(exception.message, isShort: false);
          return;
        } else if (exception.operation == EHImageExceptionAfterOperation.pauseAll) {
          toast(exception.message, isShort: false);
          return;
        } else if (exception.operation == EHImageExceptionAfterOperation.reParse) {
          GalleryImage image;
          try {
            image = await readPageLogic.requestImage(index, true, null);
          } catch (e) {
            log.error('Save original image failed: $e');
            toast('saveFailed'.tr);
            return;
          }

          readPageState.images[index]!.originalImageUrl = image.originalImageUrl;

          return saveOriginalOnlineImage(index);
        }
      } else {
        toast('saveFailed'.tr, isShort: false);
        return;
      }
    }

    try {
      if (GetPlatform.isDesktop) {
        await file.copy(join(downloadSetting.singleImageSavePath.value, fileName));
        toast('saveSuccess'.tr);
      } else {
        bool success = await _saveFile2Album(downloadPath, fileName);
        toast(success ? 'saveSuccess'.tr : 'saveFailed'.tr);
      }
    } catch (e) {
      log.error('Save original online image failed: $e');
      toast('saveFailed'.tr);
    } finally {
      file.delete().ignore();
    }
  }

  void saveLocalImage(int index) {
    if (readPageState.images[index]?.path == null) {
      saveOnlineImage(index);
      return;
    }

    String filePath = GalleryDownloadService.computeImageDownloadAbsolutePathFromRelativePath(
      galleryDownloadService
          .galleryDownloadInfos[readPageState.readPageInfo.gid!]!.images[index]!.path!,
    );
    File image = File(filePath);

    String fileName = basename(image.path);
    if (readPageState.readPageInfo.gid != null && readPageState.readPageInfo.token != null) {
      fileName =
          '${readPageState.readPageInfo.gid!}_${readPageState.readPageInfo.token!}_$index${extension(image.path)}';
    }

    if (GetPlatform.isDesktop) {
      image
          .copy(join(downloadSetting.singleImageSavePath.value, fileName))
          .then((_) => toast('success'.tr));
    } else {
      _saveFile2Album(filePath, fileName).then((_) => toast('success'.tr));
    }
  }

  /// Compute image container size when we haven't parsed image's size
  Size getPlaceHolderSize(int imageIndex) {
    if (readPageState.imageContainerSizes[imageIndex] != null) {
      return readPageState.imageContainerSizes[imageIndex]!;
    }
    return Size(double.infinity, readPageState.displayRegionSize.height / 2);
  }

  /// Compute image container size
  FittedSizes getImageFittedSize(Size imageSize) {
    if (readSetting.smartScaling.isTrue) {
      return computeSmartScalingFittedSize(
        imageSize: imageSize,
        viewportSize: readPageState.displayRegionSize,
        scrollAxis: Axis.vertical,
        thresholdPercent: readSetting.smartScalingThreshold.value,
      );
    }

    return applyBoxFit(
      BoxFit.contain,
      Size(imageSize.width, imageSize.height),
      Size(readPageState.displayRegionSize.width, double.infinity),
    );
  }

  Future<bool> _saveFile2Album(String filePath, String fileName) async {
    await requestAlbumPermission();

    SaveResult saveResult = await SaverGallery.saveFile(
      file: filePath,
      name: fileName,
      androidRelativePath: "Pictures/JHenTai",
      androidExistNotSave: false,
    );

    log.info('Save image to album: $saveResult');

    return saveResult.isSuccess;
  }

  Future<void> blockImageByHash(int index, {required bool isLocal}) async {
    GalleryImage image = readPageState.images[index]!;
    String? key = imageBlockService.buildCacheKey(image);

    if (key == null) {
      toast('blockImageFailed'.tr);
      return;
    }

    await imageBlockService.addUserBlockedHash(key);
    toast('blockImageSuccess'.tr);
  }

  void registerQrDetection(int index, QrBlockMode mode) {
    qrFirstDetectedIndex = qrFirstDetectedIndex == null ? index : min(qrFirstDetectedIndex!, index);
    qrLastDetectedIndex = qrLastDetectedIndex == null ? index : max(qrLastDetectedIndex!, index);

    if (mode == QrBlockMode.superRange && qrSuperModeStartIndex == null) {
      qrSuperModeStartIndex = index;
    }
  }

  List<String> collectRangeKeysAfterDetection({
    required QrBlockMode mode,
    required List<GalleryImage?> images,
  }) {
    switch (mode) {
      case QrBlockMode.normal:
        return const <String>[];
      case QrBlockMode.advanced:
        if (qrFirstDetectedIndex == null || qrLastDetectedIndex == null) {
          return const <String>[];
        }
        return _collectKeysInRange(images, qrFirstDetectedIndex!, qrLastDetectedIndex!);
      case QrBlockMode.superRange:
        if (qrSuperModeStartIndex == null) {
          return const <String>[];
        }
        return _collectKeysInRange(images, qrSuperModeStartIndex!, images.length - 1);
    }
  }

  bool isQrBlockRangeResolvedForIndex({
    required int index,
    required QrBlockMode mode,
  }) {
    switch (mode) {
      case QrBlockMode.normal:
        return false;
      case QrBlockMode.advanced:
        if (qrFirstDetectedIndex == null || qrLastDetectedIndex == null) {
          return false;
        }
        return index >= qrFirstDetectedIndex! && index <= qrLastDetectedIndex!;
      case QrBlockMode.superRange:
        return qrSuperModeStartIndex != null && index >= qrSuperModeStartIndex!;
    }
  }

  List<String> collectRangeKeysForIndex({
    required int index,
    required String? key,
    required QrBlockMode mode,
  }) {
    if (key == null) {
      return const <String>[];
    }

    switch (mode) {
      case QrBlockMode.normal:
        return const <String>[];
      case QrBlockMode.advanced:
        if (qrFirstDetectedIndex != null &&
            qrLastDetectedIndex != null &&
            index >= qrFirstDetectedIndex! &&
            index <= qrLastDetectedIndex!) {
          return <String>[key];
        }
        return const <String>[];
      case QrBlockMode.superRange:
        if (qrSuperModeStartIndex != null && index >= qrSuperModeStartIndex!) {
          return <String>[key];
        }
        return const <String>[];
    }
  }

  List<String> _collectKeysInRange(
    List<GalleryImage?> images,
    int start,
    int end,
  ) {
    if (images.isEmpty) {
      return const <String>[];
    }

    int safeStart = max(0, start);
    int safeEnd = min(end, images.length - 1);
    if (safeStart > safeEnd) {
      return const <String>[];
    }

    Set<String> keys = <String>{};
    for (int i = safeStart; i <= safeEnd; i++) {
      GalleryImage? image = images[i];
      if (image == null) {
        continue;
      }
      String? key = imageBlockService.buildCacheKey(image);
      if (key != null) {
        keys.add(key);
      }
    }

    return keys.toList(growable: false);
  }
}
