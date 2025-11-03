import 'dart:async';
import 'dart:convert';
import 'dart:core';
import 'dart:io' as io;

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:executor/executor.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_instance/src/extension_instance.dart';
import 'package:get/get_rx/get_rx.dart';
import 'package:get/get_state_manager/src/simple/get_controllers.dart';
import 'package:get/get_utils/get_utils.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/database/dao/gallery_dao.dart';
import 'package:jhentai/database/dao/gallery_group_dao.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/exception/eh_image_exception.dart';
import 'package:jhentai/exception/eh_parse_exception.dart';
import 'package:jhentai/extension/dio_exception_extension.dart';
import 'package:jhentai/extension/list_extension.dart';
import 'package:jhentai/model/gallery_thumbnail.dart';
import 'package:jhentai/model/gallery_url.dart';
import 'package:jhentai/model/jh_response/fetch_image_hashes_vo.dart';
import 'package:jhentai/model/jh_response/jh_response.dart';
import 'package:jhentai/network/jh_request.dart';
import 'package:jhentai/service/local_config_service.dart';
import 'package:jhentai/service/super_resolution_service.dart';
import 'package:jhentai/setting/download_setting.dart';
import 'package:jhentai/setting/site_setting.dart';
import 'package:jhentai/setting/user_setting.dart';
import 'package:jhentai/utils/convert_util.dart';
import 'package:jhentai/utils/jh_response_parser.dart';
import 'package:jhentai/utils/speed_computer.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/utils/toast_util.dart';
import 'package:path/path.dart' as path;
import 'package:path/path.dart';
import 'package:retry/retry.dart';
import 'package:drift/drift.dart';

import '../consts/locale_consts.dart';
import '../database/dao/gallery_image_dao.dart';
import '../exception/cancel_exception.dart';
import '../exception/eh_site_exception.dart';
import '../model/comic_info.dart';
import '../model/detail_page_info.dart';
import '../model/gallery_detail.dart';
import '../model/gallery_image.dart';
import '../network/eh_request.dart';
import '../pages/download/grid/mixin/grid_download_page_service_mixin.dart';
import 'jh_service.dart';
import 'path_service.dart';
import '../utils/eh_executor.dart';
import '../utils/eh_spider_parser.dart';
import '../utils/snack_util.dart';
import 'wakelock_service.dart';

/// Responsible for local images meta-data and download all images of a gallery
GalleryDownloadService galleryDownloadService = GalleryDownloadService();

class GalleryDownloadService extends GetxController
    with GridBasePageServiceMixin, JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  final String downloadImageId = 'downloadImageId';
  final String downloadImageUrlId = 'downloadImageUrlId';
  final String galleryDownloadProgressId = 'galleryDownloadProgressId';
  final String galleryDownloadSpeedComputerId = 'galleryDownloadSpeedComputerId';
  final String galleryDownloadSuccessId = 'galleryDownloadSuccessId';

  late EHExecutor executor;

  List<String> allGroups = [];
  List<GalleryDownloadedData> gallerys = [];
  Map<int, GalleryDownloadInfo> galleryDownloadInfos = {};

  List<GalleryDownloadedData> gallerysWithGroup(String group) =>
      gallerys.where((g) => galleryDownloadInfos[g.gid]!.group == group).toList();

  static const int _maxRetryTimes = 3;
  static const int _maxRetryTimes4FetchImageHashes = 1;
  static const int _maxReparseImageUrlAttempts = 3;
  static const String metadataFileName = 'metadata';
  static const int _maxTitleLength = 85;

  static const int defaultDownloadGalleryPriority = 4;
  static const int _priorityBase = 100000000;

  final Completer<bool> _completer = Completer();

  Future<bool> get completed => _completer.future;

  Worker? _downloadSettingListener;
  Worker? _downloadKeepScreenListener;

  bool _galleryDownloadsActive = false;
  bool _archiveDownloadsActive = false;
  static const String _downloadLockName = 'download';

  bool _hasActiveGalleryDownloads() {
    return galleryDownloadInfos.values.any((info) =>
        info.downloadProgress.downloadStatus == DownloadStatus.downloading ||
        info.tasks.isNotEmpty);
  }

  void _notifyDownloadActivityChanged() {
    bool active = _hasActiveGalleryDownloads();
    if (_galleryDownloadsActive == active) {
      return;
    }
    _galleryDownloadsActive = active;
    unawaited(_syncDownloadWakelock());
  }

  void updateArchiveDownloadActivity(bool active) {
    if (_archiveDownloadsActive == active) {
      return;
    }
    _archiveDownloadsActive = active;
    unawaited(_syncDownloadWakelock());
  }

  Future<void> _syncDownloadWakelock() {
    bool shouldKeepAwake = downloadSetting.keepScreenOnWhileDownloading.isTrue &&
        (_galleryDownloadsActive || _archiveDownloadsActive);

    if (shouldKeepAwake) {
      return wakelockService.acquire(_downloadLockName);
    }

    return wakelockService.release(_downloadLockName);
  }

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);

    await _instantiateFromDB();

    log.debug('Gallery download task count: ${gallerys.length}');

    _startExecutor();

    _completer.complete(true);

    if (downloadSetting.restoreTasksAutomatically.isTrue) {
      await restoreTasks();
    }

    _downloadSettingListener = everAll(
      [downloadSetting.downloadTaskConcurrency, downloadSetting.maximum, downloadSetting.period],
      (_) {
        updateExecutor();
      },
    );
    _downloadKeepScreenListener = ever(downloadSetting.keepScreenOnWhileDownloading, (_) {
      unawaited(_syncDownloadWakelock());
    });
    unawaited(_syncDownloadWakelock());
  }

  @override
  Future<void> doAfterBeanReady() async {}

  @override
  void onClose() {
    super.onClose();

    _downloadSettingListener?.dispose();
    _downloadKeepScreenListener?.dispose();
    unawaited(wakelockService.release(_downloadLockName));
  }

  bool containGallery(int gid) => galleryDownloadInfos.containsKey(gid);

  Future<void> downloadGallery(GalleryDownloadedData gallery, {bool resume = false}) async {
    GalleryDownloadedData targetGallery = gallery;
    if (!resume && gallery.downloadStatusIndex != DownloadStatus.downloading.index) {
      targetGallery = gallery.copyWith(downloadStatusIndex: DownloadStatus.downloading.index);
    }

    if (!resume && containGallery(targetGallery.gid)) {
      return;
    }

    _ensureDownloadDirExists();

    /// If it's a new download task, record info.
    if (!resume) {
      if (!await _initGalleryInfo(targetGallery)) {
        return;
      }
      _generateComicInfoInDisk(targetGallery);
    }

    galleryDownloadInfos[targetGallery.gid]!.speedComputer.start();

    log.info(
        'Begin to download gallery: ${targetGallery.title}, original: ${targetGallery.downloadOriginalImage}');

    _submitTask(
      gid: targetGallery.gid,
      priority: _computeGalleryTaskPriority(targetGallery),
      task: _downloadGalleryTask(targetGallery),
    );

    _notifyDownloadActivityChanged();
  }

  Future<void> pauseAllDownloadGallery() async {
    await Future.wait(gallerys.map(pauseDownloadGallery).toList());
  }

  Future<void> pauseDownloadGalleryByGid(int gid) async {
    GalleryDownloadedData? gallery = gallerys.firstWhereOrNull((gallery) => gallery.gid == gid);
    if (gallery != null) {
      return pauseDownloadGallery(gallery);
    }
  }

  Future<void> pauseDownloadGallery(GalleryDownloadedData gallery) async {
    GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;
    GalleryDownloadProgress downloadProgress = galleryDownloadInfo.downloadProgress;

    if (downloadProgress.downloadStatus != DownloadStatus.downloading) {
      return;
    }

    if (!await _updateGalleryInDatabase(
      GalleryDownloadedCompanion(
          gid: Value(gallery.gid), downloadStatusIndex: Value(DownloadStatus.paused.index)),
    )) {
      return;
    }

    downloadProgress.downloadStatus = DownloadStatus.paused;
    update(['$galleryDownloadProgressId::${gallery.gid}']);

    for (AsyncTask task in galleryDownloadInfo.tasks) {
      executor.cancelTask(task);
    }

    galleryDownloadInfo.tasks.clear();
    galleryDownloadInfo.cancelToken.cancel();
    galleryDownloadInfo.speedComputer.pause();

    for (GalleryImage? image in galleryDownloadInfo.images) {
      /// no need to update db
      if (image?.downloadStatus == DownloadStatus.downloading) {
        image?.downloadStatus = DownloadStatus.paused;
        update(['$downloadImageId::${gallery.gid}']);
      }
    }

    _saveGalleryMetadataInDisk(gallery);

    log.info('Pause download gallery: ${gallery.title}');

    _notifyDownloadActivityChanged();
  }

  Future<void> resumeAllDownloadGallery() async {
    await Future.wait(gallerys.map(resumeDownloadGallery).toList());
  }

  Future<void> resumeDownloadGalleryByGid(int gid) async {
    GalleryDownloadedData? gallery = gallerys.firstWhereOrNull((gallery) => gallery.gid == gid);
    if (gallery != null) {
      return resumeDownloadGallery(gallery);
    }
  }

  Future<void> resumeDownloadGallery(GalleryDownloadedData gallery) async {
    GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;
    GalleryDownloadProgress downloadProgress = galleryDownloadInfo.downloadProgress;

    if (downloadProgress.downloadStatus != DownloadStatus.paused) {
      return;
    }

    if (!await _updateGalleryInDatabase(
      GalleryDownloadedCompanion(
          gid: Value(gallery.gid), downloadStatusIndex: Value(DownloadStatus.downloading.index)),
    )) {
      return;
    }

    downloadProgress.downloadStatus = DownloadStatus.downloading;
    update(['$galleryDownloadProgressId::${gallery.gid}']);

    /// can't reuse
    galleryDownloadInfo.cancelToken = CancelToken();
    galleryDownloadInfo.speedComputer.start();

    for (GalleryImage? image in galleryDownloadInfo.images) {
      /// no need to update db
      if (image?.downloadStatus == DownloadStatus.paused) {
        image?.downloadStatus = DownloadStatus.downloading;
        update(['$downloadImageId::${gallery.gid}']);
      }
    }

    log.info('Resume download gallery: ${gallery.title}');

    _saveGalleryMetadataInDisk(gallery);

    downloadGallery(gallery, resume: true);

    _notifyDownloadActivityChanged();
  }

  Future<void> deleteGalleryByGid(int gid) async {
    GalleryDownloadedData? gallery = gallerys.firstWhereOrNull((gallery) => gallery.gid == gid);
    if (gallery != null) {
      return deleteGallery(gallery);
    }
  }

  Future<void> deleteGallery(GalleryDownloadedData gallery, {bool deleteImages = true}) async {
    await pauseDownloadGallery(gallery);

    log.info('Delete download gallery: ${gallery.title}, deleteImages:$deleteImages');

    await superResolutionService.deleteSuperResolve(gallery.gid, SuperResolutionType.gallery);

    await _clearGalleryDownloadInfoInDatabase(gallery.gid);
    if (deleteImages) {
      _clearDownloadedImageInDisk(gallery);
    }
    _clearGalleryInfoInMemory(gallery);
  }

  /// Update local downloaded gallery if there's a new version.
  Future<void> updateGallery(
      GalleryDownloadedData oldGallery, GalleryUrl newVersionGalleryUrl) async {
    log.info('update gallery: ${oldGallery.title}');

    GalleryDetail newGalleryDetail;
    try {
      ({GalleryDetail galleryDetails, String apikey}) detailPageInfo = await retry(
        () => ehRequest.requestDetailPage(
            galleryUrl: newVersionGalleryUrl.url,
            parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey),
        retryIf: (e) => e is DioException,
        maxAttempts: _maxRetryTimes,
      );
      newGalleryDetail = detailPageInfo.galleryDetails;
    } on DioException catch (e) {
      log.info('${'updateGalleryError'.tr}, reason: ${e.errorMsg}');
      snack('updateGalleryError'.tr, e.errorMsg ?? '', isShort: true);
      return;
    } on EHSiteException catch (e) {
      log.info('${'updateGalleryError'.tr}, reason: ${e.message}');
      snack('updateGalleryError'.tr, e.message, isShort: true);
      pauseAllDownloadGallery();
      return;
    }

    GalleryDownloadedData newGallery = GalleryDownloadedData(
      gid: newGalleryDetail.galleryUrl.gid,
      token: newGalleryDetail.galleryUrl.token,
      title: newGalleryDetail.japaneseTitle ?? newGalleryDetail.rawTitle,
      category: newGalleryDetail.category,
      pageCount: newGalleryDetail.pageCount,
      oldVersionGalleryUrl: oldGallery.galleryUrl,
      galleryUrl: newGalleryDetail.galleryUrl.url,
      uploader: newGalleryDetail.uploader,
      publishTime: newGalleryDetail.publishTime,
      downloadStatusIndex: DownloadStatus.downloading.index,
      insertTime: DateTime.now().toString(),
      downloadOriginalImage: oldGallery.downloadOriginalImage,
      priority: GalleryDownloadService.defaultDownloadGalleryPriority,
      sortOrder: 0,
      groupName: galleryDownloadInfos[oldGallery.gid]!.group,
      tags: tagMap2TagString(newGalleryDetail.tags),
      tagRefreshTime: DateTime.now().toString(),
    );

    downloadGallery(newGallery);
  }

  Future<void> importGallery(GalleryDownloadedData gallery, List<GalleryImage> images) async {
    if (containGallery(gallery.gid)) {
      return;
    }

    log.info('Import gallery: ${gallery.title}');

    _ensureDownloadDirExists();

    io.Directory galleryDir =
        io.Directory(computeGalleryDownloadAbsolutePath(gallery.title, gallery.gid));
    if (!galleryDir.existsSync()) {
      galleryDir.createSync(recursive: true);
    }

    List<Future> futures = [];
    List<GalleryImage> copiedImages = [];
    for (int i = 0; i < images.length; i++) {
      GalleryImage image = images[i];
      String oldPath = computeImageDownloadAbsolutePathFromRelativePath(image.path!);
      String newPath = _computeImageDownloadAbsolutePath(gallery.title, gallery.gid, image.url, i);
      futures.add(io.File(oldPath).copy(newPath));

      copiedImages.add(image.copyWith(
          path: _computeImageDownloadRelativePath(gallery.title, gallery.gid, image.url, i)));
    }

    await Future.wait(futures);

    if (!await _restoreInfoInDatabase(gallery, copiedImages)) {
      log.error('Import gallery failed: ${gallery.title}');
      _clearGalleryDownloadInfoInDatabase(gallery.gid);
      return;
    }

    _initGalleryInfoInMemory(gallery, images: copiedImages);

    _saveGalleryMetadataInDisk(gallery);
  }

  Future<void> reDownloadGalleryByGid(int gid) async {
    GalleryDownloadedData? gallery = gallerys.firstWhereOrNull((gallery) => gallery.gid == gid);
    if (gallery != null) {
      return reDownloadGallery(gallery);
    }
  }

  Future<void> reDownloadGallery(GalleryDownloadedData gallery) async {
    log.info('Re-download gallery: ${gallery.gid}');

    await deleteGallery(gallery);

    downloadGallery(gallery);
  }

  Future<void> reDownloadImage(int gid, int serialNo) async {
    GalleryDownloadedData? gallery = gallerys.singleWhereOrNull((g) => g.gid == gid);
    GalleryDownloadInfo? galleryDownloadInfo = galleryDownloadInfos[gid];
    GalleryImage? image = galleryDownloadInfo?.images[serialNo];

    if (gallery == null || galleryDownloadInfo == null || image == null) {
      return;
    }

    log.info('Re-download image, gid: $gid, index: $serialNo');

    if (galleryDownloadInfo.downloadProgress.hasDownloaded[serialNo] == true) {
      galleryDownloadInfo.downloadProgress.curCount--;
    }
    galleryDownloadInfo.downloadProgress.hasDownloaded[serialNo] = false;
    galleryDownloadInfo.speedComputer.resetProgress(serialNo);
    galleryDownloadInfo.speedComputer.start();
    await _updateImageStatus(gallery, image, serialNo, DownloadStatus.downloading);
    await _updateGalleryDownloadStatus(gallery, DownloadStatus.downloading);
    _deleteImageInDisk(image);

    update([
      '$galleryDownloadSuccessId::${gallery.gid}',
      '$galleryDownloadProgressId::${gallery.gid}'
    ]);

    _reParseImageUrlAndDownload(gallery, serialNo);
  }

  Future<void> assignPriority(GalleryDownloadedData gallery, int priority) async {
    if (priority == galleryDownloadInfos[gallery.gid]?.priority) {
      return;
    }

    log.info('Assign priority, gid: ${gallery.gid}, priority: $priority');

    if (!await _updateGalleryInDatabase(
      GalleryDownloadedCompanion(gid: Value(gallery.gid), priority: Value(priority)),
    )) {
      return;
    }

    galleryDownloadInfos[gallery.gid]!.priority = priority;

    if (galleryDownloadInfos[gallery.gid]?.downloadProgress.downloadStatus ==
        DownloadStatus.downloading) {
      await pauseDownloadGallery(gallery);
      await resumeDownloadGallery(gallery);
    }
  }

  Future<bool> updateGroupByGid(int gid, String group) async {
    GalleryDownloadedData? gallery = gallerys.firstWhereOrNull((gallery) => gallery.gid == gid);
    if (gallery != null) {
      return updateGroup(gallery, group);
    }
    return false;
  }

  Future<bool> updateGroup(GalleryDownloadedData gallery, String group) async {
    galleryDownloadInfos[gallery.gid]?.group = group;

    if (!allGroups.contains(group) && !await _addGroup(group)) {
      return false;
    }

    _sortGallerys();

    return await _updateGalleryInDatabase(
      GalleryDownloadedCompanion(gid: Value(gallery.gid), groupName: Value(group)),
    );
  }

  Future<void> renameGroup(String oldGroup, String newGroup) async {
    List<GalleryDownloadedData> galleryDownloadedDatas =
        gallerys.where((g) => galleryDownloadInfos[g.gid]!.group == oldGroup).toList();

    await appDb.transaction(() async {
      if (!allGroups.contains(newGroup) && !await _addGroup(newGroup)) {
        return;
      }

      for (GalleryDownloadedData g in galleryDownloadedDatas) {
        galleryDownloadInfos[g.gid]!.group = newGroup;
        await _updateGalleryInDatabase(
          GalleryDownloadedCompanion(gid: Value(g.gid), groupName: Value(newGroup)),
        );
        _saveGalleryMetadataInDisk(g);
      }

      await _deleteGroup(oldGroup);
    });

    _sortGallerys();
  }

  Future<void> deleteGroup(String group) {
    return _deleteGroup(group);
  }

  Future<void> updateGalleryOrder(List<GalleryDownloadedData> gallerys) async {
    await appDb.transaction(() async {
      for (GalleryDownloadedData gallery in gallerys) {
        await _updateGalleryInDatabase(
          GalleryDownloadedCompanion(
              gid: Value(gallery.gid),
              sortOrder: Value(galleryDownloadInfos[gallery.gid]!.sortOrder)),
        );
      }
    });

    _sortGallerys();
  }

  Future<void> updateGroupOrder(int beforeIndex, int afterIndex) async {
    if (afterIndex == allGroups.length - 1) {
      allGroups.add(allGroups.removeAt(beforeIndex));
    } else {
      allGroups.insert(afterIndex, allGroups.removeAt(beforeIndex));
    }

    log.info('Update group order: $allGroups');

    await appDb.transaction(() async {
      for (int i = 0; i < allGroups.length; i++) {
        await GalleryGroupDao.updateGalleryGroupOrder(allGroups[i], i);
      }
    });
  }

  bool isUpdatingDependent(int gid) {
    GalleryDownloadedData? gallery = gallerys.firstWhereOrNull((g) => g.gid == gid);
    if (gallery == null) {
      return false;
    }

    GalleryDownloadedData? oldGallery =
        gallerys.firstWhereOrNull((g) => g.oldVersionGalleryUrl == gallery.galleryUrl);
    if (oldGallery == null) {
      return false;
    }

    return galleryDownloadInfos[oldGallery.gid]!.downloadProgress.downloadStatus !=
        DownloadStatus.downloaded;
  }

  /// Use metadata in each gallery folder to restore download status, then sync to database.
  /// This is used after re-install app, or share download folder to another user.
  Future<int> restoreTasks() async {
    await completed;

    io.Directory downloadDir = io.Directory(downloadSetting.downloadPath.value);
    if (!downloadDir.existsSync()) {
      return 0;
    }

    int restoredCount = 0;
    for (io.FileSystemEntity galleryDir in downloadDir.listSync()) {
      io.File metadataFile = io.File(path.join(galleryDir.path, metadataFileName));

      /// metadata file does not exist
      if (!metadataFile.existsSync()) {
        continue;
      }

      Map metadata = jsonDecode(metadataFile.readAsStringSync());

      /// compatible with new field
      (metadata['gallery'] as Map).putIfAbsent('downloadOriginalImage', () => false);
      (metadata['gallery'] as Map).putIfAbsent('sortOrder', () => 0);
      if ((metadata['gallery'] as Map)['insertTime'] == null) {
        (metadata['gallery'] as Map)['insertTime'] = DateTime.now().toString();
      }
      if ((metadata['gallery'] as Map)['priority'] == null) {
        (metadata['gallery'] as Map)['priority'] = defaultDownloadGalleryPriority;
      }
      if ((metadata['gallery'] as Map)['groupName'] == null) {
        (metadata['gallery'] as Map)['groupName'] = 'default'.tr;
      }
      if (metadata['tags'] == null) {
        (metadata['gallery'] as Map)['tags'] = '';
      }
      if (metadata['tagRefreshTime'] == null) {
        (metadata['gallery'] as Map)['tagRefreshTime'] = DateTime.now().toString();
      }

      GalleryDownloadedData gallery = GalleryDownloadedData.fromJson(metadata['gallery']);
      List<GalleryImage?> images = (jsonDecode(metadata['images']) as List)
          .map((map) => map == null ? null : GalleryImage.fromJson(map))
          .toList();

      String? mpvKey = metadata['mpvKey'] as String?;
      List<String?>? mpvImageKeys = metadata['mpvImageKeys'] == null
          ? null
          : (jsonDecode(metadata['mpvImageKeys']) as List).map((e) => e as String?).toList();
      List<String?>? mpvSkipServerIdentifiers = metadata['mpvSkipServerIdentifiers'] == null
          ? null
          : (jsonDecode(metadata['mpvSkipServerIdentifiers']) as List)
              .map((e) => e as String?)
              .toList();

      /// skip if exists
      if (galleryDownloadInfos.containsKey(gallery.gid)) {
        continue;
      }

      /// To deal with changed download location, compute download path again.
      for (int serialNo = 0; serialNo < images.length; serialNo++) {
        if (images[serialNo] == null) {
          continue;
        }
        images[serialNo]!.path = _computeImageDownloadRelativePath(
            gallery.title, gallery.gid, images[serialNo]!.url, serialNo);
        images[serialNo]!.imageHash ??= '';
      }

      /// For some reason, downloaded status is not updated correctly, check it again
      if (gallery.downloadStatusIndex != DownloadStatus.downloaded.index) {
        int downloadedImageCount = images.fold(0,
            (total, image) => total + (image?.downloadStatus == DownloadStatus.downloaded ? 1 : 0));
        if (downloadedImageCount == gallery.pageCount) {
          gallery = gallery.copyWith(downloadStatusIndex: DownloadStatus.downloaded.index);
        }
      }

      if (!await _restoreInfoInDatabase(gallery, images)) {
        log.error('Restore download failed. Gallery: ${gallery.title}');
        _clearGalleryDownloadInfoInDatabase(gallery.gid);
        continue;
      }

      _initGalleryInfoInMemory(
        gallery,
        images: images,
        mpvKey: mpvKey,
        mpvImageKeys: mpvImageKeys,
        mpvSkipServerIdentifiers: mpvSkipServerIdentifiers,
        sort: false,
      );

      restoredCount++;
    }

    if (restoredCount > 0) {
      _sortGallerys();
    }

    return restoredCount;
  }

  Future<void> updateImagePathAfterDownloadPathChanged() async {
    await appDb.transaction(() async {
      for (GalleryDownloadedData gallery in gallerys) {
        List<GalleryImage?> images = galleryDownloadInfos[gallery.gid]!.images;

        for (int serialNo = 0; serialNo < images.length; serialNo++) {
          if (images[serialNo] == null) {
            continue;
          }

          String newPath = _computeImageDownloadRelativePath(
              gallery.title, gallery.gid, images[serialNo]!.url, serialNo);

          if (!await _updateImageInDatabase(
            ImageCompanion(
                gid: Value(gallery.gid), serialNo: Value(serialNo), path: Value(newPath)),
          )) {
            log.error('Update image path after download path changed failed');
          }
          images[serialNo]!.path = newPath;

          update([
            '$downloadImageId::${gallery.gid}::$serialNo',
            '$downloadImageUrlId::${gallery.gid}::$serialNo'
          ]);
        }
      }
    });
  }

  static EHImageException? imageData2Exception(String imageFileData) {
    if (imageFileData.isEmpty) {
      return EHImageException(
        type: EHImageExceptionType.blankImage,
        message: 'blankImageHint'.tr,
        operation: EHImageExceptionAfterOperation.reParse,
      );
    }

    if (imageFileData.contains(
        'Downloading original files of this gallery during peak hours requires GP, and you do not have enough.')) {
      return EHImageException(
        type: EHImageExceptionType.peakHours,
        message: 'peakHoursHint'.tr,
        operation: EHImageExceptionAfterOperation.pause,
      );
    }

    if (imageFileData.contains(
        'Downloading original files of this gallery requires GP, and you do not have enough.')) {
      return EHImageException(
        type: EHImageExceptionType.peakHours,
        message: 'oldGalleryHint'.tr,
        operation: EHImageExceptionAfterOperation.pause,
      );
    }

    if (imageFileData.contains(
        'You have reached the image limit, and do not have sufficient GP to buy a download quota.')) {
      return EHImageException(
        type: EHImageExceptionType.peakHours,
        message: 'exceedLimitHint'.tr,
        operation: EHImageExceptionAfterOperation.pauseAll,
      );
    }

    /// We need a token in url to get the original image download url, expired token will leads to a failed request,
    if (imageFileData.contains('Invalid token')) {
      return EHImageException(
        type: EHImageExceptionType.invalidToken,
        message: '',
        operation: EHImageExceptionAfterOperation.reParse,
      );
    }

    /// H@H node error
    if (imageFileData.contains('Invalid request')) {
      return EHImageException(
        type: EHImageExceptionType.serverError,
        message: '',
        operation: EHImageExceptionAfterOperation.reParse,
      );
    }

    /// H@H node error
    if (imageFileData.contains('An error has occurred')) {
      return EHImageException(
        type: EHImageExceptionType.serverError,
        message: '',
        operation: EHImageExceptionAfterOperation.reParse,
      );
    }

    return EHImageException(
      type: EHImageExceptionType.serverError,
      message: imageFileData,
      operation: EHImageExceptionAfterOperation.pause,
    );
  }

  Future<void> _generateComicInfoInDisk(GalleryDownloadedData gallery) async {
    GalleryDetail galleryDetail;
    try {
      ({GalleryDetail galleryDetails, String apikey}) detailPageInfo = await retry(
        () => ehRequest.requestDetailPage(
            galleryUrl: gallery.galleryUrl,
            parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey),
        retryIf: (e) => e is DioException,
        maxAttempts: _maxRetryTimes,
      );
      galleryDetail = detailPageInfo.galleryDetails;
    } catch (e) {
      log.error('Get gallery detail failed, gallery: ${gallery.gid}', e);
      return;
    }

    if (_taskHasBeenRemoved(gallery)) {
      return;
    }

    EHGalleryComicInfo galleryComicInfo = EHGalleryComicInfo(
      rawTitle: galleryDetail.rawTitle,
      japaneseTitle: galleryDetail.japaneseTitle,
      category: galleryDetail.category,
      pageCount: galleryDetail.pageCount,
      galleryUrl: galleryDetail.galleryUrl.url,
      uploader: galleryDetail.uploader,
      publishTime: galleryDetail.publishTime,
      languageAbbreviation:
          LocaleConsts.language2Abbreviation[galleryDetail.language]?.toLowerCase(),
      tagDatas:
          galleryDetail.tags.values.flattened.map((galleryTag) => galleryTag.tagData).toList(),
      rating: galleryDetail.realRating,
    );

    try {
      io.File file = io.File(path.join(
          computeGalleryDownloadAbsolutePath(gallery.title, gallery.gid), 'ComicInfo.xml'));
      if (!await file.exists()) {
        await file.create(recursive: true);
      }
      await file.writeAsString(galleryComicInfo.toXmlDocument().toXmlString(pretty: true));
    } catch (e) {
      log.error('Write comic info failed, gallery: ${gallery.gid}', e);
    }
  }

  void updateExecutor() {
    executor.concurrency = downloadSetting.downloadTaskConcurrency.value;
    executor.rate = Rate(downloadSetting.maximum.value, downloadSetting.period.value);
  }

  /// start executor
  void _startExecutor() {
    log.debug('start download executor');

    executor = EHExecutor(
      concurrency: downloadSetting.downloadTaskConcurrency.value,
      rate: Rate(downloadSetting.maximum.value, downloadSetting.period.value),
    );

    /// Resume gallery whose status is [downloading], order by insertTime
    for (GalleryDownloadedData g in gallerys) {
      if (g.downloadStatusIndex == DownloadStatus.downloading.index) {
        // gid2SpeedComputer[g.gid]!.start();
        downloadGallery(g, resume: true);
      }
    }
  }

  /// shutdown executor
  // ignore: unused_element
  Future<void> _shutdownExecutor() async {
    log.info('Shutdown download executor');

    await pauseAllDownloadGallery();
    executor.close();
  }

  void _submitTask({
    required int gid,
    required int priority,
    required AsyncTask<void> task,
  }) {
    galleryDownloadInfos[gid]?.tasks.add(task);

    executor.scheduleTask(priority, task).then((_) async {
      galleryDownloadInfos[gid]?.tasks.remove(task);
      _notifyDownloadActivityChanged();
      await _pauseGalleryIfIncompleteAndIdle(gid);
    }).onError((e, stackTrace) async {
      galleryDownloadInfos[gid]?.tasks.remove(task);
      _notifyDownloadActivityChanged();
      if (e is! CancelException) {
        log.error('Executor exception!', e, stackTrace);
        log.uploadError(e);
      }
      await _pauseGalleryIfIncompleteAndIdle(gid);
      return null;
    });
  }

  Future<void> _pauseGalleryIfIncompleteAndIdle(int gid) async {
    GalleryDownloadInfo? galleryDownloadInfo = galleryDownloadInfos[gid];
    if (galleryDownloadInfo == null) {
      return;
    }

    if (galleryDownloadInfo.tasks.isNotEmpty) {
      return;
    }

    if (galleryDownloadInfo.downloadProgress.downloadStatus == DownloadStatus.paused ||
        galleryDownloadInfo.downloadProgress.downloadStatus == DownloadStatus.downloaded) {
      return;
    }

    if (galleryDownloadInfo.downloadProgress.curCount ==
        galleryDownloadInfo.downloadProgress.totalCount) {
      return;
    }

    GalleryDownloadedData? gallery = gallerys.firstWhereOrNull((g) => g.gid == gid);
    if (gallery == null) {
      return;
    }

    log.download('Pause gallery after incomplete run. Gid: $gid');
    await _updateGalleryDownloadStatus(gallery, DownloadStatus.paused);
  }

  /// Rules:
  /// 1. If [downloadAllGallerysOfSamePriority] is false
  ///   1.1 Galleries download order:
  ///     1.1.1 gallery with high priority
  ///     1.1.2 gallery with low priority
  ///     1.1.3 if priority is same, download only 1 gallery simultaneously in the order of insert time ASC
  ///   1.2 For each gallery, previous image should be downloaded earlier
  /// 2. If [downloadAllGallerysOfSamePriority] is true
  ///   2.1 Galleries download order:
  ///     2.1.1 gallery with high priority
  ///     2.1.2 gallery with low priority
  ///     2.1.3 if priority is same, download all gallerys simultaneously
  ///   2.2 For each gallery, previous image should be downloaded earlier and images with same [serialNo] has the same priority no matter which gallery they belong to
  ///
  /// Because a gallery has most 2000 images, we assign 2000 numbers to each gallery
  int _computeGalleryTaskPriority(GalleryDownloadedData gallery) {
    if (_taskHasBeenPausedOrRemoved(gallery)) {
      return 0;
    }

    int groupPriority = galleryDownloadInfos[gallery.gid]!.priority * _priorityBase;

    if (downloadSetting.downloadAllGallerysOfSamePriority.isTrue) {
      return groupPriority;
    }

    /// priority is same, order by insert time
    DateTime insertTime = DateFormat('yyyy-MM-dd HH:mm:ss').parse(gallery.insertTime);
    int timePriority = int.parse(DateFormat('MMddHHmmss').format(insertTime)) * 2000;

    return groupPriority + timePriority;
  }

  int _computeImageTaskPriority(GalleryDownloadedData gallery, int serialNo) {
    return _computeGalleryTaskPriority(gallery) + serialNo;
  }

  String _computeGalleryTitle(String rawTitle) {
    String title = rawTitle.replaceAll(RegExp(r'[/|?,:*"<>\\.]'), ' ').trim();

    if (title.length > _maxTitleLength) {
      title = title.substring(0, _maxTitleLength).trim();
    }

    return title;
  }

  String computeGalleryDownloadAbsolutePath(String rawTitle, int gid) {
    String title = _computeGalleryTitle(rawTitle);
    return path.join(downloadSetting.downloadPath.value, '$gid - $title');
  }

  String _computeImageDownloadAbsolutePath(String title, int gid, String imageUrl, int serialNo) {
    /// original image's url doesn't has an ext
    String? ext = imageUrl.contains('fullimg.php') ? 'jpg' : imageUrl.split('.').last;

    return path.join(
      computeGalleryDownloadAbsolutePath(title, gid),
      '$serialNo.$ext',
    );
  }

  String _computeImageDownloadRelativePath(String title, int gid, String imageUrl, int serialNo) {
    return path.relative(
      _computeImageDownloadAbsolutePath(title, gid, imageUrl, serialNo),
      from: pathService.getVisibleDir().path,
    );
  }

  static String computeImageDownloadAbsolutePathFromRelativePath(String imageRelativePath) {
    String path = join(pathService.getVisibleDir().path, imageRelativePath);

    /// I don't know why some images can't be loaded on Windows... If you knows, please tell me
    if (!GetPlatform.isWindows) {
      return path;
    }

    return join(rootPrefix(path), relative(path, from: rootPrefix(path)));
  }

  void _sortGallerys() {
    gallerys.sort((a, b) {
      GalleryDownloadInfo? aInfo = galleryDownloadInfos[a.gid];
      GalleryDownloadInfo? bInfo = galleryDownloadInfos[b.gid];
      if (aInfo == null || bInfo == null) {
        return 0;
      }

      if (!(aInfo.group == 'default'.tr && bInfo.group == 'default'.tr)) {
        if (aInfo.group == 'default'.tr) {
          return 1;
        }
        if (bInfo.group == 'default'.tr) {
          return -1;
        }
      }

      int gResult = aInfo.group.compareTo(bInfo.group);
      if (gResult != 0) {
        return gResult;
      }

      int aOrder = galleryDownloadInfos[a.gid]!.sortOrder;
      int bOrder = galleryDownloadInfos[b.gid]!.sortOrder;
      if (aOrder - bOrder != 0) {
        return aOrder - bOrder;
      }

      DateTime aTime = DateFormat('yyyy-MM-dd HH:mm:ss').parse(a.insertTime);
      DateTime bTime = DateFormat('yyyy-MM-dd HH:mm:ss').parse(b.insertTime);

      return bTime.difference(aTime).inMilliseconds;
    });
  }

  bool _taskHasBeenPausedOrRemoved(GalleryDownloadedData gallery) {
    return galleryDownloadInfos[gallery.gid] == null ||
        galleryDownloadInfos[gallery.gid]!.downloadProgress.downloadStatus == DownloadStatus.paused;
  }

  bool _taskHasBeenRemoved(GalleryDownloadedData gallery) {
    return galleryDownloadInfos[gallery.gid] == null;
  }

  // Task

  AsyncTask<void> _downloadGalleryTask(GalleryDownloadedData gallery) {
    return () async {
      if (_taskHasBeenPausedOrRemoved(gallery)) {
        return;
      }

      /// If this is a update from old gallery, try to fetch image hashes from JHenTai Server
      if (gallery.oldVersionGalleryUrl != null && downloadSetting.useJH2UpdateGallery.isTrue) {
        List<String> imageHashes = await _fetchImageHashesFromJHenTaiServer(gallery);

        if (imageHashes.length == gallery.pageCount) {
          await _tryCopyImageInfosFromImageHashes(gallery, imageHashes);
        } else {
          log.error(
              'Image hashes count mismatch, gid: ${gallery.gid}, expected: ${gallery.pageCount}, actual: ${imageHashes.length}');
        }
      }

      for (int serialNo = 0; serialNo < gallery.pageCount; serialNo++) {
        _processImage(gallery, serialNo);
      }
    };
  }

  Future<List<String>> _fetchImageHashesFromJHenTaiServer(GalleryDownloadedData gallery) async {
    if (_taskHasBeenPausedOrRemoved(gallery)) {
      return [];
    }

    String? cachedImageHashes = await localConfigService.read(
        configKey: ConfigEnum.galleryImageHash, subConfigKey: gallery.gid.toString());
    if (cachedImageHashes != null) {
      return jsonDecode(cachedImageHashes).cast<String>();
    }

    GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;

    try {
      JHResponse response = await retry(
        () => jhRequest.requestGalleryImageHashes(
          gid: gallery.gid,
          token: gallery.token,
          cancelToken: galleryDownloadInfo.cancelToken,
          parser: JHResponseParser.commonParse,
        ),
        retryIf: (e) => e is DioException && e.type != DioExceptionType.cancel,
        onRetry: (e) => log.download(
            'Failed to fetch image hashes, retry. Reason: ${(e as DioException).message}'),
        maxAttempts: _maxRetryTimes4FetchImageHashes,
      );

      log.debug('Fetch image hashes response: $response');
      if (response.isSuccess) {
        FetchImageHashesVO fetchImageHashesVO = FetchImageHashesVO.fromResponse(response.data);
        localConfigService.write(
            configKey: ConfigEnum.galleryImageHash,
            subConfigKey: gallery.gid.toString(),
            value: jsonEncode(fetchImageHashesVO.hashes));
        return fetchImageHashesVO.hashes;
      } else {
        return [];
      }
    } on DioException catch (e) {
      log.error('Failed to fetch image hashes', e.errorMsg, e.stackTrace);
      return [];
    } catch (e) {
      log.error('Failed to fetch image hashes', e.toString(), StackTrace.current);
      return [];
    }
  }

  Future<void> _processImage(GalleryDownloadedData gallery, int serialNo) async {
    if (_taskHasBeenPausedOrRemoved(gallery)) {
      return;
    }

    GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;

    /// has downloaded this image => nothing to do
    if (galleryDownloadInfo.images[serialNo]?.downloadStatus == DownloadStatus.downloaded) {
      return;
    }

    /// url has been parsed => download directly
    if (galleryDownloadInfo.images[serialNo]?.url != null) {
      return _submitTask(
        gid: gallery.gid,
        priority: _computeImageTaskPriority(gallery, serialNo),
        task: _downloadImageTask(gallery, serialNo),
      );
    }

    /// has parsed href => parse url
    if (galleryDownloadInfo.imageHrefs[serialNo] != null) {
      return _submitTask(
        gid: gallery.gid,
        priority: _computeImageTaskPriority(gallery, serialNo),
        task: _parseImageUrlTask(gallery, serialNo),
      );
    }

    /// has not parsed href => parse href
    _submitTask(
      gid: gallery.gid,
      priority: _computeImageTaskPriority(gallery, serialNo),
      task: _parseImageHrefTask(gallery, serialNo),
    );
  }

  AsyncTask<void> _parseImageHrefTask(
    GalleryDownloadedData gallery,
    int serialNo, {
    String? previousFailedUrl,
    int reParseDepth = 0,
    bool forceRefresh = false,
  }) {
    return () async {
      if (_taskHasBeenPausedOrRemoved(gallery)) {
        return;
      }

      GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;
      int requestPageIndex = serialNo ~/ galleryDownloadInfo.thumbnailsCountPerPage;

      if (forceRefresh) {
        await ehRequest.removeCacheByGalleryUrlAndPage(gallery.galleryUrl, requestPageIndex);
      }

      DetailPageInfo detailPageInfo;
      try {
        detailPageInfo = await retry(
          () => ehRequest.requestDetailPage(
            galleryUrl: gallery.galleryUrl,
            thumbnailsPageIndex: requestPageIndex,
            cancelToken: galleryDownloadInfo.cancelToken,
            parser: EHSpiderParser.detailPage2RangeAndThumbnails,
          ),
          delayFactor: const Duration(milliseconds: 500),
          retryIf: (e) => e is DioException && e.type != DioExceptionType.cancel,
          onRetry: (e) => log.download(
              'Parse image hrefs failed, retry. Reason: ${(e as DioException).toString()}'),
          maxAttempts: _maxRetryTimes,
        );
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          return;
        }
        return _submitTask(
          gid: gallery.gid,
          priority: _computeImageTaskPriority(gallery, serialNo),
          task: _parseImageHrefTask(
            gallery,
            serialNo,
            previousFailedUrl: previousFailedUrl,
            reParseDepth: reParseDepth,
          ),
        );
      } on EHSiteException catch (e) {
        log.download(
            'Parse image href error, reason: ${e.message}, gallery url: ${gallery.galleryUrl}');
        snack('error'.tr, e.message, isShort: true);
        if (e.shouldPauseAllDownloadTasks) {
          pauseAllDownloadGallery();
        } else {
          pauseDownloadGallery(gallery);
        }
        return;
      }

      /// some gallery's [thumbnailsCountPerPage] is not equal to default setting, we need to compute and update it.
      /// For example, default setting is 40, but some gallerys' thumbnails has only high quality thumbnails, which results in 20.
      bool thumbnailsCountPerPageChanged =
          galleryDownloadInfo.thumbnailsCountPerPage != detailPageInfo.thumbnailsCountPerPage;
      galleryDownloadInfo.thumbnailsCountPerPage = detailPageInfo.thumbnailsCountPerPage;

      for (int i = detailPageInfo.imageNoFrom; i <= detailPageInfo.imageNoTo; i++) {
        galleryDownloadInfo.imageHrefs[i] =
            detailPageInfo.thumbnails[i - detailPageInfo.imageNoFrom];
      }

      /// if gallery's [thumbnailsCountPerPage] is not equal to default setting, we probably can't get target thumbnails this turn
      /// because the [thumbnailsPageIndex] we computed before is wrong, so we need to parse again
      if (galleryDownloadInfo.imageHrefs[serialNo] == null) {
        log.download(
          'Parse image hrefs error, thumbnails count per page is not equal to default setting, parse again. Thumbnails count per page: ${detailPageInfo.thumbnailsCountPerPage}, changed: $thumbnailsCountPerPageChanged',
        );
        await ehRequest.removeCacheByGalleryUrlAndPage(gallery.galleryUrl, requestPageIndex);
        return _submitTask(
          gid: gallery.gid,
          priority: _computeImageTaskPriority(gallery, serialNo),
          task: _parseImageHrefTask(
            gallery,
            serialNo,
            previousFailedUrl: previousFailedUrl,
            reParseDepth: reParseDepth + 1,
            forceRefresh: forceRefresh,
          ),
        );
      }

      /// Next step: parse image url
      _submitTask(
        gid: gallery.gid,
        priority: _computeImageTaskPriority(gallery, serialNo),
        task: _parseImageUrlTask(
          gallery,
          serialNo,
          previousFailedUrl: previousFailedUrl,
          reParseDepth: reParseDepth,
        ),
      );
    };
  }

  AsyncTask<void> _parseImageUrlTask(
    GalleryDownloadedData gallery,
    int serialNo, {
    bool reParse = false,
    String? reloadKey,
    String? previousFailedUrl,
    int reParseDepth = 0,
    bool? preferOriginalOverride,
  }) {
    return () async {
      if (_taskHasBeenPausedOrRemoved(gallery)) {
        return;
      }

      GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;

      /// If this is a update from old gallery, try to copy from existing old image first
      if (gallery.oldVersionGalleryUrl != null) {
        await _tryCopyImageInfoFromHref(gallery.oldVersionGalleryUrl!, gallery, serialNo);

        if (galleryDownloadInfo.images[serialNo] != null) {
          return;
        }
      }

      bool preferOriginal =
          preferOriginalOverride ?? galleryDownloadInfo.preferOriginalImages[serialNo];
      if (preferOriginal != galleryDownloadInfo.preferOriginalImages[serialNo]) {
        galleryDownloadInfo.preferOriginalImages[serialNo] = preferOriginal;
      }

      bool useOriginal = preferOriginal && userSetting.hasLoggedIn();
      if (preferOriginal && !userSetting.hasLoggedIn()) {
        useOriginal = false;
        galleryDownloadInfo.preferOriginalImages[serialNo] = false;
      }

      GalleryThumbnail? thumbnail = galleryDownloadInfo.imageHrefs[serialNo];
      if (thumbnail == null) {
        log.download(
            'Image href missing when parsing image url, re-parse href. Gid: ${gallery.gid}, index: $serialNo');
        return _submitTask(
          gid: gallery.gid,
          priority: _computeImageTaskPriority(gallery, serialNo),
          task: _parseImageHrefTask(
            gallery,
            serialNo,
            previousFailedUrl: previousFailedUrl,
            reParseDepth: reParseDepth + 1,
            forceRefresh: true,
          ),
        );
      }

      bool usedMpvFlow = false;
      String? mpvKeyForRequest;
      String? mpvImageKeyForRequest;
      String? mpvReloadKeyForRequest;
      GalleryImage image;
      try {
        Future<GalleryImage> Function()? requestImageFactory;

        if (thumbnail.isMPV) {
          galleryDownloadInfo.mpvKey ??= thumbnail.mpvKey;

          try {
            await _ensureMpvImageKeys(
              gallery,
              galleryDownloadInfo,
              thumbnail,
              serialNo,
            );
          } on EHParseException catch (e) {
            if (e.type != EHParseExceptionType.unsupportedImagePageStyle) {
              rethrow;
            }
            log.download(
                'MPV page unsupported, fall back to legacy parser. Gid: ${gallery.gid}, index: $serialNo');
          }

          mpvKeyForRequest = galleryDownloadInfo.mpvKey ?? thumbnail.mpvKey;
          mpvImageKeyForRequest = galleryDownloadInfo.mpvImageKeys[serialNo];

          if (mpvKeyForRequest != null && mpvImageKeyForRequest != null) {
            usedMpvFlow = true;
            mpvReloadKeyForRequest =
                reloadKey ?? galleryDownloadInfo.mpvSkipServerIdentifiers[serialNo];
            requestImageFactory = () => ehRequest.requestMpvImage(
                  gid: gallery.gid,
                  page: serialNo + 1,
                  imgKey: mpvImageKeyForRequest!,
                  mpvKey: mpvKeyForRequest!,
                  reloadKey: mpvReloadKeyForRequest,
                  cancelToken: galleryDownloadInfo.cancelToken,
                  parser: useOriginal
                      ? EHSpiderParser.imagePage2OriginalGalleryImage
                      : EHSpiderParser.imagePage2GalleryImage,
                );
          } else {
            log.download(
                'MPV imagelist missing key, fall back to legacy parser. Gid: ${gallery.gid}, index: $serialNo');
          }
        }

        requestImageFactory ??= () => ehRequest.requestImagePage(
              thumbnail.replacedMPVHref(serialNo + 1),
              reloadKey: reloadKey,
              cancelToken: galleryDownloadInfo.cancelToken,
              useCacheIfAvailable: !reParse,
              parser: useOriginal
                  ? EHSpiderParser.imagePage2OriginalGalleryImage
                  : EHSpiderParser.imagePage2GalleryImage,
            );

        image = await retry(
          requestImageFactory,
          retryIf: (e) => e is DioException && e.type != DioExceptionType.cancel,
          onRetry: (e) => log
              .download('Parse image url failed, retry. Reason: ${(e as DioException).errorMsg}'),
          delayFactor: const Duration(milliseconds: 500),
          maxAttempts: _maxRetryTimes,
        );
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          return;
        }
        return _submitTask(
          gid: gallery.gid,
          priority: _computeImageTaskPriority(gallery, serialNo),
          task: _parseImageUrlTask(
            gallery,
            serialNo,
            reParse: true,
            reloadKey: reloadKey,
            previousFailedUrl: previousFailedUrl,
            reParseDepth: reParseDepth,
          ),
        );
      } on EHParseException catch (e) {
        log.download('Parse image url error, reason: ${e.message.tr}');
        snack('error'.tr, e.message.tr, isShort: true);

        if (e.shouldPauseAllDownloadTasks) {
          pauseAllDownloadGallery();
        } else {
          pauseDownloadGallery(gallery);
        }

        ehRequest.removeCacheByUrl(
            galleryDownloadInfo.imageHrefs[serialNo]!.replacedMPVHref(serialNo + 1));

        return;
      } on EHSiteException catch (e) {
        log.download('Parse image url error, reason: ${e.message.tr}');
        snack('error'.tr, e.message.tr, isShort: true);

        if (e.shouldPauseAllDownloadTasks) {
          pauseAllDownloadGallery();
        } else {
          pauseDownloadGallery(gallery);
        }

        return;
      }

      if (usedMpvFlow && mpvKeyForRequest != null && mpvImageKeyForRequest != null) {
        bool metadataChanged = false;
        if (galleryDownloadInfo.mpvKey != mpvKeyForRequest) {
          galleryDownloadInfo.mpvKey = mpvKeyForRequest;
          metadataChanged = true;
        }
        if (galleryDownloadInfo.mpvImageKeys[serialNo] != mpvImageKeyForRequest) {
          galleryDownloadInfo.mpvImageKeys[serialNo] = mpvImageKeyForRequest;
          metadataChanged = true;
        }
        if (galleryDownloadInfo.mpvSkipServerIdentifiers[serialNo] != image.reloadKey) {
          galleryDownloadInfo.mpvSkipServerIdentifiers[serialNo] = image.reloadKey;
          metadataChanged = true;
        }
        if (metadataChanged) {
          _saveGalleryMetadataInDisk(gallery);
        }
      }

      if (previousFailedUrl != null && image.url == previousFailedUrl) {
        if (reParseDepth < _maxReparseImageUrlAttempts) {
          log.download(
              'Parse image url returned identical url, wait and retry. Gid: ${gallery.gid}, index: $serialNo, attempt: ${reParseDepth + 1}');
          await Future.delayed(const Duration(milliseconds: 1000), () {});
          if (image.reloadKey != null) {
            log.download(
                'Parse image url returned identical url, retry with new reload key. Gid: ${gallery.gid}, index: $serialNo, reloadKey: ${image.reloadKey}, attempt: ${reParseDepth + 1}');
            return _submitTask(
              gid: gallery.gid,
              priority: _computeImageTaskPriority(gallery, serialNo),
              task: _parseImageUrlTask(
                gallery,
                serialNo,
                reParse: true,
                reloadKey: image.reloadKey,
                previousFailedUrl: previousFailedUrl,
                reParseDepth: reParseDepth + 1,
              ),
            );
          }

          log.download(
              'Parse image url returned identical url, force re-parse href. Gid: ${gallery.gid}, index: $serialNo, attempt: ${reParseDepth + 1}');
          GalleryThumbnail? thumbnail = galleryDownloadInfo.imageHrefs[serialNo];
          if (thumbnail != null) {
            await ehRequest.removeCacheByUrl(thumbnail.replacedMPVHref(serialNo + 1));
          }
          return _submitTask(
            gid: gallery.gid,
            priority: _computeImageTaskPriority(gallery, serialNo),
            task: _parseImageHrefTask(
              gallery,
              serialNo,
              previousFailedUrl: previousFailedUrl,
              reParseDepth: reParseDepth + 1,
              forceRefresh: true,
            ),
          );
        }
      }

      if (previousFailedUrl != null && image.url == previousFailedUrl) {
        log.download(
            'Parse image url returned identical url after all retries, mark as failed. Gid: ${gallery.gid}, index: $serialNo');
        image.path =
            _computeImageDownloadRelativePath(gallery.title, gallery.gid, image.url, serialNo);
        image.downloadStatus = DownloadStatus.downloadFailed;
        galleryDownloadInfo.images[serialNo] = image;
        await _saveNewImageInfoInDatabase(image, serialNo, gallery.gid);
        await _markImageAsFailed(gallery, image, serialNo);
        snack('error'.tr, 'downloadFailed'.tr, isShort: true);
        return;
      }

      image.path =
          _computeImageDownloadRelativePath(gallery.title, gallery.gid, image.url, serialNo);
      image.downloadStatus = DownloadStatus.downloading;

      await _saveNewImageInfoInDatabase(image, serialNo, gallery.gid);

      galleryDownloadInfo.images[serialNo] = image;

      log.download('Parse image url success, index: $serialNo, url: ${image.url}');

      /// Next step: download image
      return _submitTask(
        gid: gallery.gid,
        priority: _computeImageTaskPriority(gallery, serialNo),
        task: _downloadImageTask(gallery, serialNo),
      );
    };
  }

  AsyncTask<void> _downloadImageTask(GalleryDownloadedData gallery, int serialNo) {
    return () async {
      if (_taskHasBeenPausedOrRemoved(gallery)) {
        return;
      }

      GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;
      GalleryImage image = galleryDownloadInfo.images[serialNo]!;

      _updateImageStatus(gallery, image, serialNo, DownloadStatus.downloading);

      /// If this is a update from old gallery, try to copy from existing old image first
      if (gallery.oldVersionGalleryUrl != null) {
        await _tryCopyImageInfoFromImage(gallery.oldVersionGalleryUrl!, gallery, serialNo);

        if (image.downloadStatus == DownloadStatus.downloaded) {
          return;
        }
      }

      String path =
          _computeImageDownloadAbsolutePath(gallery.title, gallery.gid, image.url, serialNo);

      await _tryLoadFromCacheInsteadDownload(gallery, image, serialNo, path);
      if (image.downloadStatus == DownloadStatus.downloaded) {
        return;
      }

      Response response;
      try {
        response = await retry(
          () => ehRequest.download(
            url: image.url,
            path: path,
            receiveTimeout: 3 * 60 * 1000,
            cancelToken: galleryDownloadInfo.cancelToken,
            onReceiveProgress: (int count, int total) =>
                galleryDownloadInfo.speedComputer.updateProgress(count, total, serialNo),
          ),
          delayFactor: const Duration(milliseconds: 500),
          maxAttempts: _maxRetryTimes,

          /// 403 or 5xx indicate broken H@H nodes, so we should re-parse instead of retrying
          /// If we have not downloaded any bytes, skip retry to trigger re-parse for dead nodes
          retryIf: (e) {
            if (e is! DioException || e.type == DioExceptionType.cancel) {
              return false;
            }

            int? statusCode = e.response?.statusCode;
            if (statusCode == 403) {
              return false;
            }
            if (statusCode != null && statusCode >= 500 && statusCode < 600) {
              return false;
            }

            if (e.error is io.HttpException || e.error is io.SocketException) {
              return false;
            }

            return galleryDownloadInfo.speedComputer.getImageDownloadedBytes(serialNo) > 0;
          },
          onRetry: (e) {
            log.download(
                'Download ${gallery.title} image: $serialNo failed, retry. Reason: ${(e as DioException).errorMsg}. Url:${image.url}');
            galleryDownloadInfo.speedComputer.resetProgress(serialNo);
          },
        );
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          return;
        }
        log.download(
            'Download ${gallery.title} image: $serialNo failed, try re-parse. Reason: ${e.errorMsg}. Url:${image.url}');
        galleryDownloadInfo.speedComputer.resetProgress(serialNo);
        return _reParseImageUrlAndDownload(gallery, serialNo);
      } on io.HttpException catch (e) {
        log.download(
            'Download ${gallery.title} image: $serialNo failed, try re-parse. Reason: ${e.message}. Url:${image.url}');
        galleryDownloadInfo.speedComputer.resetProgress(serialNo);
        return _reParseImageUrlAndDownload(gallery, serialNo);
      } on io.SocketException catch (e) {
        log.download(
            'Download ${gallery.title} image: $serialNo failed, try re-parse. Reason: ${e.message}. Url:${image.url}');
        galleryDownloadInfo.speedComputer.resetProgress(serialNo);
        return _reParseImageUrlAndDownload(gallery, serialNo);
      } on EHSiteException catch (e) {
        log.download('Download Error, reason: ${e.message}');
        snack('error'.tr, e.message, isShort: true);

        if (e.shouldPauseAllDownloadTasks) {
          pauseAllDownloadGallery();
        } else {
          pauseDownloadGallery(gallery);
        }
        return;
      }

      final int? statusCode = response.statusCode;
      if (statusCode == 403) {
        log.download(
            'Download ${gallery.title} image: $serialNo failed with status 403, try re-parse. Url:${image.url}');
        galleryDownloadInfo.speedComputer.resetProgress(serialNo);
        return _reParseImageUrlAndDownload(gallery, serialNo);
      }

      io.File downloadedFile = io.File(path);
      if (!downloadedFile.existsSync() || downloadedFile.lengthSync() == 0) {
        log.download(
            'Download ${gallery.title} image: $serialNo returned empty content, try re-parse. Url:${image.url}');
        galleryDownloadInfo.speedComputer.resetProgress(serialNo);
        if (downloadedFile.existsSync()) {
          try {
            downloadedFile.deleteSync();
          } catch (e, stack) {
            log.error('Delete empty image file failed', e, stack);
          }
        }
        return _reParseImageUrlAndDownload(gallery, serialNo);
      }

      /// what we downloaded is not an valid image
      if (!response.isRedirect &&
          (response.headers[Headers.contentTypeHeader]?.contains("text/html; charset=UTF-8") ??
              false)) {
        String data = downloadedFile.readAsStringSync();

        EHImageException? exception = imageData2Exception(data);
        log.error('Download ${gallery.title} image: $serialNo failed: $exception');

        if (exception != null) {
          if (exception.operation == EHImageExceptionAfterOperation.pause) {
            snack('error'.tr, exception.message, isShort: true);
            return pauseDownloadGallery(gallery);
          } else if (exception.operation == EHImageExceptionAfterOperation.pauseAll) {
            snack('error'.tr, exception.message, isShort: true);
            return pauseAllDownloadGallery();
          } else if (exception.operation == EHImageExceptionAfterOperation.reParse) {
            return _reParseImageUrlAndDownload(gallery, serialNo);
          }
        } else {
          snack('error'.tr, 'downloadFailed'.tr, isShort: true);
          return pauseDownloadGallery(gallery);
        }
      }

      log.download('Download ${gallery.title} image: $serialNo success');

      await _updateImageStatus(gallery, image, serialNo, DownloadStatus.downloaded);

      await _updateProgressAfterImageDownloaded(gallery, serialNo);
    };
  }

  /// the image's url may be invalid, try re-parse and then download
  Future<void> _reParseImageUrlAndDownload(GalleryDownloadedData gallery, int serialNo) async {
    if (_taskHasBeenPausedOrRemoved(gallery)) {
      return;
    }

    GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;

    GalleryImage? existingImage = galleryDownloadInfo.images[serialNo];
    bool preferOriginalImage = galleryDownloadInfo.preferOriginalImages[serialNo];

    String? reloadKey = existingImage?.reloadKey;
    String? previousUrl = existingImage?.url;
    Set<String> triedLegacyReloadKeys = galleryDownloadInfo.legacyReloadKeyHistory[serialNo];
    bool triedLegacyWithoutKey = galleryDownloadInfo.legacyReloadTriedWithoutKey[serialNo];

    if (reloadKey != null) {
      triedLegacyReloadKeys.add(reloadKey);
    }

    if (preferOriginalImage && existingImage != null && previousUrl != null) {
      String? legacyReloadKey = await _fetchLegacyReloadKeyForOriginalImage(
        gallery,
        galleryDownloadInfo,
        serialNo,
        reloadKey,
      );

      if (legacyReloadKey != null) {
        if (triedLegacyReloadKeys.contains(legacyReloadKey)) {
          if (!triedLegacyWithoutKey) {
            galleryDownloadInfo.legacyReloadTriedWithoutKey[serialNo] = true;
            log.download(
                'Legacy reload key loop, retry without reload key. Gid: ${gallery.gid}, index: $serialNo');
            existingImage.originalImageUrl ??= _stripReloadKeyFromUrl(previousUrl);
            existingImage.url =
                _stripReloadKeyFromUrl(existingImage.originalImageUrl ?? previousUrl);
            existingImage.reloadKey = null;
            existingImage.downloadStatus = DownloadStatus.downloading;

            galleryDownloadInfo.images[serialNo] = existingImage;
            galleryDownloadInfo.mpvSkipServerIdentifiers[serialNo] = null;

            bool updated = await _updateImageInDatabase(
              ImageCompanion(
                gid: Value(gallery.gid),
                serialNo: Value(serialNo),
                url: Value(existingImage.url),
                downloadStatusIndex: Value(DownloadStatus.downloading.index),
              ),
            );
            if (!updated) {
              await GalleryImageDao.deleteImage(gallery.gid, serialNo);
              await _saveNewImageInfoInDatabase(existingImage, serialNo, gallery.gid);
            }

            _saveGalleryMetadataInDisk(gallery);
            log.download(
                'Re-parse image url by stripping legacy reload key. Gid: ${gallery.gid}, index: $serialNo, url: ${existingImage.url}');
            return _submitTask(
              gid: gallery.gid,
              priority: _computeImageTaskPriority(gallery, serialNo),
              task: _downloadImageTask(gallery, serialNo),
            );
          }

          log.download(
              'Legacy reload key loop persists after stripping reload key, mark failed. Gid: ${gallery.gid}, index: $serialNo');
          await _markImageAsFailed(gallery, existingImage, serialNo);
          return;
        }

        triedLegacyReloadKeys.add(legacyReloadKey);
        existingImage.originalImageUrl ??= _stripReloadKeyFromUrl(previousUrl);
        existingImage.url =
            _appendReloadKeyToOriginalUrl(existingImage.originalImageUrl!, legacyReloadKey);
        existingImage.reloadKey = legacyReloadKey;
        existingImage.downloadStatus = DownloadStatus.downloading;

        galleryDownloadInfo.images[serialNo] = existingImage;
        galleryDownloadInfo.mpvSkipServerIdentifiers[serialNo] = legacyReloadKey;

        bool updated = await _updateImageInDatabase(
          ImageCompanion(
            gid: Value(gallery.gid),
            serialNo: Value(serialNo),
            url: Value(existingImage.url),
            downloadStatusIndex: Value(DownloadStatus.downloading.index),
          ),
        );
        if (!updated) {
          await GalleryImageDao.deleteImage(gallery.gid, serialNo);
          await _saveNewImageInfoInDatabase(existingImage, serialNo, gallery.gid);
        }

        _saveGalleryMetadataInDisk(gallery);
        log.download(
            'Re-parse image url success using legacy reload key. Gid: ${gallery.gid}, index: $serialNo, url: ${existingImage.url}');
        return _submitTask(
          gid: gallery.gid,
          priority: _computeImageTaskPriority(gallery, serialNo),
          task: _downloadImageTask(gallery, serialNo),
        );
      }
    }

    galleryDownloadInfo.images[serialNo] = null;
    await GalleryImageDao.deleteImage(gallery.gid, serialNo);

    /// has parsed href => parse url
    if (galleryDownloadInfo.imageHrefs[serialNo] != null) {
      return _submitTask(
        gid: gallery.gid,
        priority: _computeImageTaskPriority(gallery, serialNo),
        task: _parseImageUrlTask(
          gallery,
          serialNo,
          reParse: true,
          reloadKey: reloadKey,
          previousFailedUrl: previousUrl,
        ),
      );
    }

    /// has not parsed href => parse href
    return _submitTask(
      gid: gallery.gid,
      priority: _computeImageTaskPriority(gallery, serialNo),
      task: _parseImageHrefTask(
        gallery,
        serialNo,
        previousFailedUrl: previousUrl,
      ),
    );
  }

  Future<void> _ensureMpvImageKeys(
    GalleryDownloadedData gallery,
    GalleryDownloadInfo galleryDownloadInfo,
    GalleryThumbnail thumbnail,
    int serialNo,
  ) async {
    if (galleryDownloadInfo.mpvImageKeys[serialNo] != null &&
        (galleryDownloadInfo.mpvKey ?? thumbnail.mpvKey) != null) {
      return;
    }

    Future<void>? inFlight = galleryDownloadInfo.mpvKeysFuture;
    if (inFlight != null) {
      await inFlight;
    }

    if (galleryDownloadInfo.mpvImageKeys[serialNo] != null &&
        (galleryDownloadInfo.mpvKey ?? thumbnail.mpvKey) != null) {
      return;
    }

    Future<void> fetchFuture = _fetchMpvKeys(gallery, galleryDownloadInfo, thumbnail);
    galleryDownloadInfo.mpvKeysFuture = fetchFuture;
    try {
      await fetchFuture;
    } finally {
      if (identical(galleryDownloadInfo.mpvKeysFuture, fetchFuture)) {
        galleryDownloadInfo.mpvKeysFuture = null;
      }
    }

    galleryDownloadInfo.mpvKey ??= thumbnail.mpvKey;
  }

  Future<void> _fetchMpvKeys(
    GalleryDownloadedData gallery,
    GalleryDownloadInfo galleryDownloadInfo,
    GalleryThumbnail thumbnail,
  ) async {
    String mpvUrl = thumbnail.href.split('#').first;
    if (mpvUrl.isEmpty) {
      throw EHParseException(
        type: EHParseExceptionType.unsupportedImagePageStyle,
        message: 'unsupportedImagePageStyle'.tr,
        shouldPauseAllDownloadTasks: false,
      );
    }

    final result = await ehRequest.requestMpvPage(
      mpvUrl,
      cancelToken: galleryDownloadInfo.cancelToken,
      parser: EHSpiderParser.mpvPage2MpvKeyAndImageKeys,
    );

    bool metadataChanged = false;
    if (galleryDownloadInfo.mpvKey != result.mpvKey) {
      galleryDownloadInfo.mpvKey = result.mpvKey;
      metadataChanged = true;
    }

    result.imageKeys.forEach((page, key) {
      int index = page - 1;
      if (index < 0 || index >= galleryDownloadInfo.mpvImageKeys.length) {
        return;
      }
      if (galleryDownloadInfo.mpvImageKeys[index] != key) {
        galleryDownloadInfo.mpvImageKeys[index] = key;
        metadataChanged = true;
      }
    });

    if (metadataChanged) {
      _saveGalleryMetadataInDisk(gallery);
    }
  }

  Future<String?> _fetchLegacyReloadKeyForOriginalImage(
    GalleryDownloadedData gallery,
    GalleryDownloadInfo galleryDownloadInfo,
    int serialNo,
    String? currentReloadKey,
  ) async {
    GalleryThumbnail? thumbnail = galleryDownloadInfo.imageHrefs[serialNo];
    if (thumbnail == null) {
      return null;
    }

    try {
      GalleryImage legacyImage = await retry(
        () => ehRequest.requestImagePage(
          thumbnail.replacedMPVHref(serialNo + 1),
          reloadKey: currentReloadKey,
          cancelToken: galleryDownloadInfo.cancelToken,
          useCacheIfAvailable: false,
          parser: EHSpiderParser.imagePage2GalleryImage,
        ),
        retryIf: (e) => e is DioException && e.type != DioExceptionType.cancel,
        onRetry: (e) => log.download(
            'Fetch legacy reload key failed, retry. Reason: ${(e as DioException).errorMsg}'),
        delayFactor: const Duration(milliseconds: 500),
        maxAttempts: _maxRetryTimes,
      );
      log.download(
          'Fetch legacy reload key success. Gid: ${gallery.gid}, index: $serialNo, reloadKey: ${legacyImage.reloadKey}');
      return legacyImage.reloadKey;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        return null;
      }
      log.download(
          'Fetch legacy reload key failed. Gid: ${gallery.gid}, index: $serialNo, reason: ${e.errorMsg}');
      return null;
    } on EHParseException catch (e) {
      log.download(
          'Fetch legacy reload key parse error. Gid: ${gallery.gid}, index: $serialNo, reason: ${e.message.tr}');
      return null;
    } on EHSiteException catch (e) {
      log.download(
          'Fetch legacy reload key site error. Gid: ${gallery.gid}, index: $serialNo, reason: ${e.message.tr}');
      return null;
    }
  }

  String _appendReloadKeyToOriginalUrl(String url, String reloadKey) {
    String reloadValue = reloadKey;
    try {
      Uri uri = Uri.parse(url);
      Map<String, String> query = Map<String, String>.from(uri.queryParameters);
      if (query['nl'] == reloadValue) {
        return uri.toString();
      }
      query['nl'] = reloadValue;
      return uri.replace(queryParameters: query).toString();
    } catch (_) {
      int questionMarkIndex = url.indexOf('?');
      if (questionMarkIndex == -1) {
        return '$url?nl=$reloadValue';
      }

      String base = url.substring(0, questionMarkIndex);
      String query = url.substring(questionMarkIndex + 1);
      List<String> params = query
          .split('&')
          .where((segment) => segment.isNotEmpty && !segment.startsWith('nl='))
          .toList();
      params.add('nl=$reloadValue');

      return '$base?${params.join('&')}';
    }
  }

  String _stripReloadKeyFromUrl(String url) {
    int questionMarkIndex = url.indexOf('?');
    if (questionMarkIndex == -1) {
      return url;
    }

    String base = url.substring(0, questionMarkIndex);
    String query = url.substring(questionMarkIndex + 1);
    List<String> params = query
        .split('&')
        .where((segment) => segment.isNotEmpty && !segment.startsWith('nl='))
        .toList();

    return params.isEmpty ? base : '$base?${params.join('&')}';
  }

  Future<void> _markImageAsFailed(
      GalleryDownloadedData gallery, GalleryImage image, int serialNo) async {
    GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;
    galleryDownloadInfo.images[serialNo] = image;

    galleryDownloadInfo.speedComputer.resetProgress(serialNo);
    await _updateImageStatus(gallery, image, serialNo, DownloadStatus.downloadFailed);
  }

  Future<void> _tryCopyImageInfoFromHref(
      String oldVersionGalleryUrl, GalleryDownloadedData newGallery, int newImageSerialNo) async {
    GalleryDownloadedData? oldGallery =
        gallerys.firstWhereOrNull((e) => e.galleryUrl == oldVersionGalleryUrl);
    if (oldGallery == null) {
      return;
    }

    String? newImageHash =
        galleryDownloadInfos[newGallery.gid]!.imageHrefs[newImageSerialNo]!.originImageHash;
    if (newImageHash == null) {
      return;
    }

    int? oldImageSerialNo = galleryDownloadInfos[oldGallery.gid]
        ?.images
        .firstIndexWhereOrNull((e) => e?.imageHash == newImageHash);
    if (oldImageSerialNo == null) {
      return;
    }

    GalleryImage oldImage = galleryDownloadInfos[oldGallery.gid]!.images[oldImageSerialNo]!;
    GalleryImage newImage = oldImage.copyWith(
      path: _computeImageDownloadRelativePath(
          newGallery.title, newGallery.gid, oldImage.url, newImageSerialNo),
      downloadStatus: DownloadStatus.downloading,
    );

    await _saveNewImageInfoInDatabase(newImage, newImageSerialNo, newGallery.gid);
    galleryDownloadInfos[newGallery.gid]!.images[newImageSerialNo] = newImage;

    await _copyImageInfo(oldImage, newGallery, newImageSerialNo);
    await superResolutionService.copyImageInfo(
        oldGallery, newGallery, oldImageSerialNo, newImageSerialNo);
  }

  /// If two images' [imageHash] is equal, they are the same image.
  Future<void> _tryCopyImageInfoFromImage(
      String oldVersionGalleryUrl, GalleryDownloadedData newGallery, int newImageSerialNo) async {
    GalleryDownloadedData? oldGallery =
        gallerys.firstWhereOrNull((e) => e.galleryUrl == oldVersionGalleryUrl);
    if (oldGallery == null) {
      return;
    }

    String newImageHash =
        galleryDownloadInfos[newGallery.gid]!.images[newImageSerialNo]!.imageHash!;
    int? oldImageSerialNo = galleryDownloadInfos[oldGallery.gid]
        ?.images
        .firstIndexWhereOrNull((e) => e?.imageHash == newImageHash);
    if (oldImageSerialNo == null) {
      return;
    }

    GalleryImage oldImage = galleryDownloadInfos[oldGallery.gid]!.images[oldImageSerialNo]!;

    await _copyImageInfo(oldImage, newGallery, newImageSerialNo);
    await superResolutionService.copyImageInfo(
        oldGallery, newGallery, oldImageSerialNo, newImageSerialNo);
  }

  Future<void> _tryCopyImageInfosFromImageHashes(
      GalleryDownloadedData newGallery, List<String> imageHashes) async {
    GalleryDownloadedData? oldGallery =
        gallerys.firstWhereOrNull((e) => e.galleryUrl == newGallery.oldVersionGalleryUrl);
    if (oldGallery == null) {
      return;
    }

    for (int serialNo = 0; serialNo < newGallery.pageCount; serialNo++) {
      if (_taskHasBeenPausedOrRemoved(newGallery)) {
        break;
      }

      GalleryDownloadInfo newGalleryDownloadInfo = galleryDownloadInfos[newGallery.gid]!;
      if (newGalleryDownloadInfo.images[serialNo]?.downloadStatus == DownloadStatus.downloaded) {
        continue;
      }

      int? oldImageSerialNo = galleryDownloadInfos[oldGallery.gid]
          ?.images
          .firstIndexWhereOrNull((e) => e?.imageHash == imageHashes[serialNo]);
      if (oldImageSerialNo == null) {
        continue;
      }

      GalleryImage oldImage = galleryDownloadInfos[oldGallery.gid]!.images[oldImageSerialNo]!;

      GalleryImage newImage = oldImage.copyWith(
        path: _computeImageDownloadRelativePath(
            newGallery.title, newGallery.gid, oldImage.url, serialNo),
        downloadStatus: DownloadStatus.downloaded,
      );

      log.download('Copy old image, new serialNo: $serialNo');
      io.File oldFile = io.File(path.join(pathService.getVisibleDir().path, oldImage.path!));
      await oldFile.copy(path.join(pathService.getVisibleDir().path, newImage.path!));

      if (newGalleryDownloadInfo.images[serialNo] == null) {
        await _saveNewImageInfoInDatabase(newImage, serialNo, newGallery.gid);
        newGalleryDownloadInfo.images[serialNo] = newImage;
      } else {
        await _updateImageStatus(newGallery, newImage, serialNo, DownloadStatus.downloaded);
      }

      await _updateProgressAfterImageDownloaded(newGallery, serialNo);

      await superResolutionService.copyImageInfo(
          oldGallery, newGallery, oldImageSerialNo, serialNo);
    }

    _saveGalleryMetadataInDisk(newGallery);
  }

  Future<void> _copyImageInfo(
      GalleryImage oldImage, GalleryDownloadedData newGallery, int newImageSerialNo) async {
    log.download('Copy old image, new serialNo: $newImageSerialNo');

    GalleryImage newImage = galleryDownloadInfos[newGallery.gid]!.images[newImageSerialNo]!;

    io.File oldFile = io.File(path.join(pathService.getVisibleDir().path, oldImage.path!));
    await oldFile.copy(path.join(pathService.getVisibleDir().path, newImage.path!));

    await _updateImageStatus(newGallery, newImage, newImageSerialNo, DownloadStatus.downloaded);

    await _updateProgressAfterImageDownloaded(newGallery, newImageSerialNo);
  }

  Future<void> _tryLoadFromCacheInsteadDownload(
      GalleryDownloadedData gallery, GalleryImage image, int serialNo, String path) async {
    io.File? cachedImageFile = await getCachedImageFile(image.url);
    if (cachedImageFile != null && cachedImageFile.existsSync()) {
      log.debug('download image from cache, gallery: ${gallery.gid}, serialNo:$serialNo');
      await cachedImageFile.copy(path);
      await _updateImageStatus(gallery, image, serialNo, DownloadStatus.downloaded);
      await _updateProgressAfterImageDownloaded(gallery, serialNo);
    }
  }

  Future<void> _updateProgressAfterImageDownloaded(
      GalleryDownloadedData gallery, int serialNo) async {
    if (_taskHasBeenRemoved(gallery)) {
      return;
    }

    GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;
    galleryDownloadInfo.legacyReloadKeyHistory[serialNo].clear();
    galleryDownloadInfo.legacyReloadTriedWithoutKey[serialNo] = false;

    GalleryDownloadProgress downloadProgress = galleryDownloadInfo.downloadProgress;
    downloadProgress.curCount++;
    downloadProgress.hasDownloaded[serialNo] = true;

    if (downloadProgress.curCount == downloadProgress.totalCount) {
      downloadProgress.downloadStatus = DownloadStatus.downloaded;
      await _updateGalleryDownloadStatus(gallery, DownloadStatus.downloaded);
      galleryDownloadInfo.speedComputer.dispose();
      update(['$galleryDownloadSuccessId::${gallery.gid}']);
    }

    update(['$galleryDownloadProgressId::${gallery.gid}']);
  }

  // ALL

  Future<void> _instantiateFromDB() async {
    allGroups = (await GalleryGroupDao.selectGalleryGroups()).map((e) => e.groupName).toList();
    log.debug('init Gallery groups: $allGroups');

    /// Get download info from database
    List<GalleryDownloadedData> gallerys = await GalleryDao.selectGallerys();
    List<ImageData> images = await GalleryImageDao.selectImages();
    Map<int, List<ImageData>> gid2Images = groupBy(images, (e) => e.gid);

    for (GalleryDownloadedData gallery in gallerys) {
      /// Instantiate [Gallery]
      _initGalleryInfoInMemory(gallery, sort: false);

      /// Instantiate [GalleryImage]
      List<ImageData>? galleryImages = gid2Images[gallery.gid];
      if (galleryImages != null) {
        for (ImageData image in galleryImages) {
          GalleryImage galleryImage = GalleryImage(
            url: image.url,
            path: image.path,
            imageHash: image.imageHash,
            downloadStatus: DownloadStatus.values[image.downloadStatusIndex],
          );

          galleryDownloadInfos[gallery.gid]!.images[image.serialNo] = galleryImage;
          if (galleryImage.downloadStatus == DownloadStatus.downloaded) {
            galleryDownloadInfos[gallery.gid]!.downloadProgress.curCount++;
            galleryDownloadInfos[gallery.gid]!.downloadProgress.hasDownloaded[image.serialNo] =
                true;
          }
        }
      }
    }

    // sort after instantiated
    _sortGallerys();
  }

  Future<bool> _initGalleryInfo(GalleryDownloadedData gallery) async {
    if (!await _saveGalleryInfoAndGroupInDB(gallery)) {
      return false;
    }

    _initGalleryInfoInMemory(gallery);

    _saveGalleryMetadataInDisk(gallery);

    return true;
  }

  Future<void> _updateGalleryDownloadStatus(
      GalleryDownloadedData gallery, DownloadStatus downloadStatus) async {
    await _updateGalleryInDatabase(
      GalleryDownloadedCompanion(
          gid: Value(gallery.gid), downloadStatusIndex: Value(downloadStatus.index)),
    );

    gallerys[gallerys.indexWhere((e) => e.gid == gallery.gid)] =
        gallery.copyWith(downloadStatusIndex: downloadStatus.index);
    galleryDownloadInfos[gallery.gid]!.downloadProgress.downloadStatus = downloadStatus;

    _saveGalleryMetadataInDisk(gallery);

    _notifyDownloadActivityChanged();
  }

  Future<bool> _updateImageStatus(GalleryDownloadedData gallery, GalleryImage image, int serialNo,
      DownloadStatus downloadStatus) async {
    DownloadStatus previousStatus = image.downloadStatus;
    if (!await _updateImageInDatabase(
      ImageCompanion(
          gid: Value(gallery.gid),
          serialNo: Value(serialNo),
          downloadStatusIndex: Value(downloadStatus.index)),
    )) {
      return false;
    }

    image.downloadStatus = downloadStatus;

    GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;

    if (downloadStatus == DownloadStatus.downloading &&
        previousStatus != DownloadStatus.downloading) {
      galleryDownloadInfo.legacyReloadKeyHistory[serialNo].clear();
      galleryDownloadInfo.legacyReloadTriedWithoutKey[serialNo] = false;
    }

    if (downloadStatus == DownloadStatus.downloadFailed &&
        galleryDownloadInfo.downloadProgress.hasDownloaded[serialNo]) {
      galleryDownloadInfo.downloadProgress.hasDownloaded[serialNo] = false;
      if (galleryDownloadInfo.downloadProgress.curCount > 0) {
        galleryDownloadInfo.downloadProgress.curCount--;
      }
    }

    update([
      '$downloadImageId::${gallery.gid}::$serialNo',
      '$downloadImageUrlId::${gallery.gid}::$serialNo'
    ]);

    _saveGalleryMetadataInDisk(gallery);

    return true;
  }

  Future<bool> _addGroup(String group) async {
    if (!allGroups.contains(group)) {
      allGroups.add(group);
    }

    return (await GalleryGroupDao.insertGalleryGroup(
            GalleryGroupData(groupName: group, sortOrder: 0)) >
        0);
  }

  Future<bool> _deleteGroup(String group) async {
    allGroups.remove(group);

    try {
      return (await GalleryGroupDao.deleteGalleryGroup(group) > 0);
    } on SqliteException catch (e) {
      log.info(e);
      return false;
    }
  }

  // MEMORY

  void _initGalleryInfoInMemory(
    GalleryDownloadedData gallery, {
    List<GalleryImage?>? images,
    List<String?>? mpvImageKeys,
    List<String?>? mpvSkipServerIdentifiers,
    String? mpvKey,
    bool sort = true,
  }) {
    if (!allGroups.contains(gallery.groupName)) {
      allGroups.add(gallery.groupName);
    }
    gallerys.add(gallery);

    List<GalleryImage?> resolvedImages = images ?? List.generate(gallery.pageCount, (_) => null);
    if (resolvedImages.length != gallery.pageCount) {
      resolvedImages = List<GalleryImage?>.from(resolvedImages)..length = gallery.pageCount;
    }

    List<String?> resolvedMpvImageKeys = mpvImageKeys == null
        ? List<String?>.filled(gallery.pageCount, null, growable: false)
        : List<String?>.from(mpvImageKeys);
    if (resolvedMpvImageKeys.length != gallery.pageCount) {
      resolvedMpvImageKeys = List<String?>.from(resolvedMpvImageKeys)..length = gallery.pageCount;
    }

    List<String?> resolvedMpvSkipServerIdentifiers = mpvSkipServerIdentifiers == null
        ? List<String?>.filled(gallery.pageCount, null, growable: false)
        : List<String?>.from(mpvSkipServerIdentifiers);
    if (resolvedMpvSkipServerIdentifiers.length != gallery.pageCount) {
      resolvedMpvSkipServerIdentifiers = List<String?>.from(resolvedMpvSkipServerIdentifiers)
        ..length = gallery.pageCount;
    }

    List<bool> hasDownloadedFlags = List.generate(
      gallery.pageCount,
      (index) => resolvedImages[index]?.downloadStatus == DownloadStatus.downloaded,
    );

    List<bool> preferOriginalImages = List.generate(gallery.pageCount, (index) {
      GalleryImage? image = resolvedImages[index];
      if (image == null) {
        return gallery.downloadOriginalImage;
      }
      if (image.originalImageUrl != null && image.originalImageUrl != image.url) {
        return false;
      }
      return gallery.downloadOriginalImage;
    });

    galleryDownloadInfos[gallery.gid] = GalleryDownloadInfo(
      thumbnailsCountPerPage: SiteSetting.thumbnailsCountPerPage.value,
      tasks: [],
      cancelToken: CancelToken(),
      downloadProgress: GalleryDownloadProgress(
        curCount: hasDownloadedFlags.where((flag) => flag).length,
        totalCount: gallery.pageCount,
        downloadStatus: DownloadStatus.values[gallery.downloadStatusIndex],
        hasDownloaded: hasDownloadedFlags,
      ),
      imageHrefs: List.generate(gallery.pageCount, (_) => null),
      images: resolvedImages,
      preferOriginalImages: preferOriginalImages,
      legacyReloadKeyHistory: List.generate(gallery.pageCount, (_) => <String>{}, growable: false),
      legacyReloadTriedWithoutKey: List<bool>.filled(gallery.pageCount, false, growable: false),
      speedComputer: GalleryDownloadSpeedComputer(
        gallery.pageCount,
        () => update(['$galleryDownloadSpeedComputerId::${gallery.gid}']),
      ),
      priority: gallery.priority,
      sortOrder: gallery.sortOrder,
      group: gallery.groupName,
      mpvKey: mpvKey,
      mpvImageKeys: resolvedMpvImageKeys,
      mpvSkipServerIdentifiers: resolvedMpvSkipServerIdentifiers,
    );

    if (sort) {
      _sortGallerys();
    }

    update([galleryCountChangedId, '$galleryDownloadProgressId::${gallery.gid}']);

    _notifyDownloadActivityChanged();

    _notifyDownloadActivityChanged();
  }

  void _clearGalleryInfoInMemory(GalleryDownloadedData gallery) {
    gallerys.removeWhere((g) => g.gid == gallery.gid);
    GalleryDownloadInfo? galleryDownloadInfo = galleryDownloadInfos.remove(gallery.gid);
    galleryDownloadInfo?.speedComputer.dispose();

    update([galleryCountChangedId, '$galleryDownloadProgressId::${gallery.gid}']);
  }

  // DB

  Future<bool> _saveGalleryInfoAndGroupInDB(GalleryDownloadedData gallery) async {
    return appDb.transaction(() async {
      await GalleryGroupDao.insertGalleryGroup(
          GalleryGroupData(groupName: gallery.groupName, sortOrder: 0));

      return await GalleryDao.insertGallery(
            GalleryDownloadedCompanion.insert(
              gid: Value(gallery.gid),
              token: gallery.token,
              title: gallery.title,
              category: gallery.category,
              pageCount: gallery.pageCount,
              galleryUrl: gallery.galleryUrl,
              oldVersionGalleryUrl: Value(gallery.oldVersionGalleryUrl),
              uploader: Value(gallery.uploader),
              publishTime: gallery.publishTime,
              downloadStatusIndex: gallery.downloadStatusIndex,
              insertTime: gallery.insertTime,
              downloadOriginalImage: Value(gallery.downloadOriginalImage),
              priority: gallery.priority,
              sortOrder: Value(gallery.sortOrder),
              groupName: gallery.groupName,
              tags: Value(gallery.tags),
              tagRefreshTime: Value(gallery.tagRefreshTime),
            ),
          ) >
          0;
    });
  }

  Future<bool> _saveNewImageInfoInDatabase(GalleryImage image, int serialNo, int gid) async {
    return await GalleryImageDao.insertImage(
          ImageData(
            gid: gid,
            serialNo: serialNo,
            url: image.url,
            path: image.path!,
            imageHash: image.imageHash ?? '',
            downloadStatusIndex: image.downloadStatus.index,
          ),
        ) >
        0;
  }

  Future<bool> _updateGalleryInDatabase(GalleryDownloadedCompanion gallery) async {
    return await GalleryDao.updateGallery(gallery) > 0;
  }

  Future<bool> _updateImageInDatabase(ImageCompanion image) async {
    return await GalleryImageDao.updateImage(image) > 0;
  }

  Future<void> _clearGalleryDownloadInfoInDatabase(int gid) {
    return appDb.transaction(() async {
      await GalleryImageDao.deleteImagesWithGid(gid);
      await GalleryDao.deleteGallery(gid);
    });
  }

  Future<bool> _restoreInfoInDatabase(
      GalleryDownloadedData gallery, List<GalleryImage?> images) async {
    if (gallery.downloadStatusIndex == DownloadStatus.downloading.index) {
      gallery = gallery.copyWith(downloadStatusIndex: DownloadStatus.paused.index);
    }

    if (!await _saveGalleryInfoAndGroupInDB(gallery)) {
      return false;
    }

    return await appDb.transaction(() async {
      int serialNo = 0;

      Iterator iterator = images.iterator;
      while (iterator.moveNext()) {
        GalleryImage? image = iterator.current;

        if (image == null) {
          serialNo++;
          continue;
        }

        if (!await _saveNewImageInfoInDatabase(image, serialNo++, gallery.gid)) {
          return false;
        }
      }

      return true;
    }).catchError((e) {
      log.error('Restore images into database error}', e);
      log.uploadError(e);
      return false;
    });
  }

  // Disk

  void _saveGalleryMetadataInDisk(GalleryDownloadedData gallery) {
    GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;

    Map<String, Object?> metadata = {
      'gallery': gallery
          .copyWith(
            downloadStatusIndex: galleryDownloadInfo.downloadProgress.downloadStatus.index,
            priority: galleryDownloadInfo.priority,
            groupName: galleryDownloadInfo.group,
          )
          .toJson(),
      'images': jsonEncode(galleryDownloadInfo.images),
    };

    metadata['mpvKey'] = galleryDownloadInfo.mpvKey;
    metadata['mpvImageKeys'] = jsonEncode(galleryDownloadInfo.mpvImageKeys);
    metadata['mpvSkipServerIdentifiers'] = jsonEncode(galleryDownloadInfo.mpvSkipServerIdentifiers);

    io.File file = io.File(path.join(
        computeGalleryDownloadAbsolutePath(gallery.title, gallery.gid), metadataFileName));
    if (!file.existsSync()) {
      file.createSync(recursive: true);
    }
    file.writeAsStringSync(jsonEncode(metadata));
  }

  void _clearDownloadedImageInDisk(GalleryDownloadedData gallery) {
    io.Directory directory =
        io.Directory(computeGalleryDownloadAbsolutePath(gallery.title, gallery.gid));
    if (!directory.existsSync()) {
      return;
    }
    directory.deleteSync(recursive: true);
  }

  void _deleteImageInDisk(GalleryImage image) {
    try {
      io.File file = io.File(image.path!);
      if (!file.existsSync()) {
        return;
      }
      file.deleteSync();
    } on Exception catch (e) {
      log.error('Delete image in disk error', e);
      log.uploadError(e);
    }
  }

  void _ensureDownloadDirExists() {
    try {
      io.Directory(downloadSetting.downloadPath.value).createSync(recursive: true);
    } on Exception catch (e) {
      toast('brokenDownloadPathHint'.tr);
      log.error(e);
      log.uploadError(
        e,
        extraInfos: {
          'defaultDownloadPath': downloadSetting.defaultDownloadPath,
          'downloadPath': downloadSetting.downloadPath.value,
          'exists': pathService.getVisibleDir().existsSync(),
        },
      );
    }
  }
}

enum DownloadStatus {
  none,
  switching,
  paused,
  downloading,
  downloaded,
  downloadFailed,
}

class GalleryDownloadInfo {
  /// 20, 40 and so on
  int thumbnailsCountPerPage;

  /// Tasks in Executor
  List<AsyncTask> tasks;

  /// Token for cancel all tasks related to a gallery
  CancelToken cancelToken;

  GalleryDownloadProgress downloadProgress;

  /// Thumbnail related to a image, whose property [href] is the page url which contains the image
  List<GalleryThumbnail?> imageHrefs;

  List<GalleryImage?> images;

  /// Track whether each image should still prefer original assets.
  List<bool> preferOriginalImages;

  /// Cache legacy reload keys we've already tried for each image to avoid loops.
  List<Set<String>> legacyReloadKeyHistory;

  /// Track whether we have already retried without any legacy reload key.
  List<bool> legacyReloadTriedWithoutKey;

  GalleryDownloadSpeedComputer speedComputer;

  int priority;

  int sortOrder;

  String group;

  String? mpvKey;

  List<String?> mpvImageKeys;

  List<String?> mpvSkipServerIdentifiers;

  Future<void>? mpvKeysFuture;

  GalleryDownloadInfo({
    required this.thumbnailsCountPerPage,
    required this.tasks,
    required this.cancelToken,
    required this.downloadProgress,
    required this.imageHrefs,
    required this.images,
    required this.preferOriginalImages,
    required this.legacyReloadKeyHistory,
    required this.legacyReloadTriedWithoutKey,
    required this.speedComputer,
    required this.priority,
    required this.sortOrder,
    required this.group,
    this.mpvKey,
    required this.mpvImageKeys,
    required this.mpvSkipServerIdentifiers,
    this.mpvKeysFuture,
  });
}

class GalleryDownloadProgress {
  /// downloaded images count
  int curCount;

  /// total images count
  int totalCount;

  DownloadStatus downloadStatus;

  List<bool> hasDownloaded;

  GalleryDownloadProgress({
    required this.curCount,
    required this.totalCount,
    required this.downloadStatus,
    required this.hasDownloaded,
  });

  Map<String, dynamic> toJson() {
    return {
      "curCount": curCount,
      "totalCount": totalCount,
      "downloadStatus": downloadStatus.index,
      "hasDownloaded": jsonEncode(hasDownloaded),
    };
  }

  factory GalleryDownloadProgress.fromJson(Map<String, dynamic> json) {
    return GalleryDownloadProgress(
      curCount: json["curCount"],
      totalCount: json["totalCount"],
      downloadStatus: DownloadStatus.values[json["downloadStatus"]],
      hasDownloaded: (jsonDecode(json["hasDownloaded"]) as List).cast<bool>(),
    );
  }
}

/// Compute gallery download speed during last period every second
class GalleryDownloadSpeedComputer extends SpeedComputer {
  List<int> imageDownloadedBytes;
  List<int> imageTotalBytes;

  GalleryDownloadSpeedComputer(int pageCount, VoidCallback updateCallback)
      : imageDownloadedBytes = List.generate(pageCount, (_) => 0),
        imageTotalBytes = List.generate(pageCount, (_) => 1),
        super(updateCallback: updateCallback);

  void updateProgress(int current, int total, int serialNo) {
    imageTotalBytes[serialNo] = total;

    downloadedBytes -= imageDownloadedBytes[serialNo];
    imageDownloadedBytes[serialNo] = current;
    downloadedBytes += imageDownloadedBytes[serialNo];
  }

  /// one image download failed
  void resetProgress(int serialNo) {
    downloadedBytes -= imageDownloadedBytes[serialNo];
    imageDownloadedBytes[serialNo] = 0;
  }

  int getImageDownloadedBytes(int serialNo) {
    return imageDownloadedBytes[serialNo];
  }
}
