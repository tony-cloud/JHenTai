import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/consts/rpc_consts.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/exception/eh_site_exception.dart';
import 'package:jhentai/extension/dio_exception_extension.dart';
import 'package:jhentai/extension/get_logic_extension.dart';
import 'package:jhentai/mixin/update_global_gallery_status_logic_mixin.dart';
import 'package:jhentai/model/gallery.dart';
import 'package:jhentai/model/gallery_archive.dart';
import 'package:jhentai/model/gallery_detail.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/network/rpc_request.dart';
import 'package:jhentai/pages/base/base_page_logic.dart';
import 'package:jhentai/pages/base/multi_select/multi_select_batch_download_util.dart';
import 'package:jhentai/pages/base/multi_select/multi_select_gallery_state_mixin.dart';
import 'package:jhentai/service/archive_download_service.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/gallery_update_queue_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/setting/download_setting.dart';
import 'package:jhentai/setting/rpc_setting.dart';
import 'package:jhentai/setting/user_setting.dart';
import 'package:jhentai/service/rpc_service.dart';
import 'package:jhentai/utils/convert_util.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';
import 'package:jhentai/utils/snack_util.dart';
import 'package:jhentai/utils/toast_util.dart';
import 'package:jhentai/widget/eh_batch_download_dialog.dart';
import 'package:jhentai/widget/eh_download_dialog.dart';
import 'package:jhentai/widget/fade_slide_widget.dart';

mixin MultiSelectGalleryLogicMixin on BasePageLogic {
  MultiSelectGalleryStateMixin get multiSelectGalleryState;

  final String multiSelectBottomBarId = 'multiSelectBottomBarId';
  bool _isHandlingBatchDownloadAndUpdate = false;

  bool get isHandlingBatchDownloadAndUpdate => _isHandlingBatchDownloadAndUpdate;

  bool get useRpcBatchDownloadAndUpdate {
    if (GetPlatform.isWeb) {
      return true;
    }

    if (rpcSetting.enableRpcMode.isFalse) {
      return false;
    }

    if (rpcService.capabilities.isNotEmpty &&
        !rpcService.supportsCapability(RPCCapabilities.downloadGalleryBatch)) {
      log.warning(
        'RPC capability ${RPCCapabilities.downloadGalleryBatch} '
        'is not reported by backend, still trying RPC call',
      );
    }

    return true;
  }

  @override
  Future<void> handleClearAndRefresh() {
    if (multiSelectGalleryState.inMultiSelectMode) {
      exitSelectMode();
    }
    return super.handleClearAndRefresh();
  }

  @override
  Future<void> handleRefresh({String? updateId}) {
    if (multiSelectGalleryState.inMultiSelectMode) {
      exitSelectMode();
    }
    return super.handleRefresh(updateId: updateId);
  }

  @override
  void handleTapGalleryCard(Gallery gallery) {
    if (multiSelectGalleryState.inMultiSelectMode) {
      toggleSelectItem(gallery);
      return;
    }
    super.handleTapGalleryCard(gallery);
  }

  @override
  void handleLongPressCard(BuildContext context, Gallery gallery) {
    if (!multiSelectGalleryState.inMultiSelectMode) {
      enterSelectMode();
      multiSelectGalleryState.selectedGids.add(gallery.gid);
      updateSafely([bodyId, multiSelectBottomBarId]);
      return;
    }

    toggleSelectItem(gallery);
  }

  @override
  void handleSecondaryTapCard(BuildContext context, Gallery gallery) {
    handleLongPressCard(context, gallery);
  }

  void enterSelectMode() {
    if (multiSelectGalleryState.inMultiSelectMode) {
      return;
    }
    multiSelectGalleryState.inMultiSelectMode = true;
    toast('multiSelectHint'.tr);
    updateSafely([multiSelectBottomBarId]);
  }

  void exitSelectMode() {
    if (!multiSelectGalleryState.inMultiSelectMode &&
        multiSelectGalleryState.selectedGids.isEmpty) {
      return;
    }

    multiSelectGalleryState.inMultiSelectMode = false;
    multiSelectGalleryState.selectedGids.clear();
    updateSafely([bodyId, multiSelectBottomBarId]);
  }

  void toggleSelectItem(Gallery gallery) {
    if (multiSelectGalleryState.selectedGids.contains(gallery.gid)) {
      multiSelectGalleryState.selectedGids.remove(gallery.gid);
    } else {
      multiSelectGalleryState.selectedGids.add(gallery.gid);
    }

    if (multiSelectGalleryState.selectedGids.isEmpty) {
      exitSelectMode();
    } else {
      updateSafely([bodyId, multiSelectBottomBarId]);
    }
  }

  void selectAllGalleries() {
    if (!multiSelectGalleryState.inMultiSelectMode) {
      enterSelectMode();
    }

    multiSelectGalleryState.selectedGids
      ..clear()
      ..addAll(state.gallerys.map((gallery) => gallery.gid));

    updateSafely([bodyId, multiSelectBottomBarId]);
  }

  Future<void> handleBatchDownload() async {
    if (multiSelectGalleryState.selectedGids.isEmpty) {
      return;
    }

    final List<Gallery> selectedGallerys = state.gallerys
        .where((gallery) => multiSelectGalleryState.selectedGids.contains(gallery.gid))
        .toList();

    if (selectedGallerys.isEmpty) {
      exitSelectMode();
      return;
    }

    final ({String group, bool downloadOriginalImage})? result = await Get.dialog(
      EHDownloadDialog(
        title: 'chooseGroup'.tr,
        currentGroup: downloadSetting.defaultGalleryGroup.value,
        candidates: galleryDownloadService.allGroups,
        showDownloadOriginalImageCheckBox: userSetting.hasLoggedIn(),
        downloadOriginalImage: downloadSetting.downloadOriginalImageByDefault.value,
      ),
    );

    if (result == null) {
      return;
    }

    int successCount = 0;
    int failedCount = 0;

    for (final Gallery gallery in selectedGallerys) {
      final GalleryDownloadedData? downloadData = await _prepareDownloadData(
        gallery,
        group: result.group,
        downloadOriginalImage: result.downloadOriginalImage,
      );

      if (downloadData == null) {
        failedCount++;
        continue;
      }

      if (galleryDownloadService.containGallery(downloadData.gid)) {
        continue;
      }

      await galleryDownloadService.downloadGallery(downloadData);
      successCount++;
    }

    if (successCount > 0) {
      toast('${'beginToDownload'.tr} ($successCount)');

      if (this is UpdateGlobalGalleryStatusLogicMixin) {
        (this as UpdateGlobalGalleryStatusLogicMixin).updateGlobalGalleryStatus();
      }
    }

    if (failedCount > 0) {
      snack('failed'.tr, '${'download'.tr}: $failedCount', isShort: true);
    }

    exitSelectMode();
  }

  Future<void> handleBatchDownloadAndUpdateSelected() async {
    if (multiSelectGalleryState.selectedGids.isEmpty) {
      return;
    }

    if (_isHandlingBatchDownloadAndUpdate) {
      toast('downloadAndUpdateBusy'.tr, isCenter: false);
      return;
    }

    final List<Gallery> selectedGallerys = state.gallerys
        .where((gallery) => multiSelectGalleryState.selectedGids.contains(gallery.gid))
        .toList();

    if (selectedGallerys.isEmpty) {
      exitSelectMode();
      return;
    }

    final EHBatchDownloadConfig? result = await showBatchDownloadAndUpdateDialog();

    if (result == null) {
      return;
    }

    await runBatchDownloadAndUpdate(
      selectedGallerys,
      config: result,
      exitSelectModeAfter: true,
    );
  }

  Future<EHBatchDownloadConfig?> showBatchDownloadAndUpdateDialog() {
    return Get.dialog(
      EHBatchDownloadDialog(
        title: 'chooseGroup'.tr,
        currentGroup: downloadSetting.defaultGalleryGroup.value,
        candidates: galleryDownloadService.allGroups,
        showDownloadOriginalImageCheckBox: userSetting.hasLoggedIn(),
        downloadOriginalImage: downloadSetting.downloadOriginalImageByDefault.value,
      ),
    );
  }

  Future<void> runBatchDownloadAndUpdate(
    List<Gallery> targetGallerys, {
    required EHBatchDownloadConfig config,
    bool exitSelectModeAfter = false,
  }) async {
    if (useRpcBatchDownloadAndUpdate) {
      return _runRpcBatchDownloadAndUpdate(
        targetGallerys,
        config: config,
        exitSelectModeAfter: exitSelectModeAfter,
      );
    }

    if (_isHandlingBatchDownloadAndUpdate) {
      toast('downloadAndUpdateBusy'.tr, isCenter: false);
      return;
    }

    if (targetGallerys.isEmpty) {
      if (exitSelectModeAfter) {
        exitSelectMode();
      }
      return;
    }

    _isHandlingBatchDownloadAndUpdate = true;

    try {
      await galleryDownloadService.completed;
      await archiveDownloadService.completed;

      final Map<int, GalleryDownloadedData> downloadedGallerysByGid = <int, GalleryDownloadedData>{
        for (final GalleryDownloadedData gallery in galleryDownloadService.gallerys)
          gallery.gid: gallery,
      };
      final Set<int> archiveGids =
          archiveDownloadService.archives.map((archive) => archive.gid).toSet();
      final Set<int> handledGids = <int>{};
      final List<GalleryDownloadedData> updateCandidates = <GalleryDownloadedData>[];

      int queuedDownloadCount = 0;
      int failedCount = 0;

      for (int index = 0; index < targetGallerys.length; index++) {
        final Gallery gallery = targetGallerys[index];

        if (!handledGids.add(gallery.gid)) {
          continue;
        }

        final GalleryDownloadedData? downloadedGallery = downloadedGallerysByGid[gallery.gid];
        final DownloadStatus? downloadStatus = downloadedGallery == null
            ? null
            : galleryDownloadService
                .galleryDownloadInfos[gallery.gid]?.downloadProgress.downloadStatus;

        switch (decideBatchGalleryDownloadAction(
          hasGalleryRecord: downloadedGallery != null,
          galleryStatus: downloadStatus,
          hasArchiveRecord: archiveGids.contains(gallery.gid),
        )) {
          case BatchGalleryDownloadAction.update:
            updateCandidates.add(downloadedGallery!);
            break;
          case BatchGalleryDownloadAction.download:
            final bool queued = await _queueNewGalleryDownload(
              gallery,
              config: config,
            );

            if (queued) {
              queuedDownloadCount++;
            } else {
              failedCount++;
            }
            break;
          case BatchGalleryDownloadAction.skip:
            break;
        }

        if ((index + 1) % 5 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      int updateQueuedCount = 0;

      if (updateCandidates.isNotEmpty) {
        final bool started = galleryUpdateQueueService.startOneKeyUpdateQueue(
          updateCandidates,
        );

        if (started) {
          updateQueuedCount = updateCandidates.length;
        } else {
          failedCount += updateCandidates.length;
        }
      }

      if ((queuedDownloadCount > 0 || updateQueuedCount > 0) &&
          this is UpdateGlobalGalleryStatusLogicMixin) {
        (this as UpdateGlobalGalleryStatusLogicMixin).updateGlobalGalleryStatus();
      }

      showBatchDownloadAndUpdateResult(
        queuedDownloadCount: queuedDownloadCount,
        updateQueuedCount: updateQueuedCount,
        failedCount: failedCount,
      );
    } finally {
      _isHandlingBatchDownloadAndUpdate = false;

      if (exitSelectModeAfter) {
        exitSelectMode();
      }
    }
  }

  Map<String, dynamic> buildBatchDownloadConfigPayload(EHBatchDownloadConfig config) {
    return <String, dynamic>{
      'group': config.group,
      'downloadOriginalImage': config.downloadOriginalImage,
      'useArchiveForNewGalleryOnly': config.useArchiveForNewGalleryOnly,
    };
  }

  void showBatchDownloadAndUpdateResult({
    required int queuedDownloadCount,
    required int updateQueuedCount,
    required int failedCount,
    bool aborted = false,
  }) {
    if (aborted && queuedDownloadCount == 0 && updateQueuedCount == 0) {
      toast('${'downloadAndUpdate'.tr}: ${'stop'.tr}', isCenter: false);
      return;
    }

    if (queuedDownloadCount > 0 || updateQueuedCount > 0) {
      toast(
        '${'downloadAndUpdateQueued'.tr}: '
        '${'download'.tr} $queuedDownloadCount, '
        '${'updateGallery'.tr} $updateQueuedCount',
        isCenter: false,
      );
    } else if (failedCount == 0) {
      toast('downloadAndUpdateNoTask'.tr, isCenter: false);
    }

    if (failedCount > 0) {
      snack(
        'failed'.tr,
        '${'downloadAndUpdate'.tr}: $failedCount',
        isShort: true,
      );
    }
  }

  Future<void> _runRpcBatchDownloadAndUpdate(
    List<Gallery> targetGallerys, {
    required EHBatchDownloadConfig config,
    required bool exitSelectModeAfter,
  }) async {
    if (_isHandlingBatchDownloadAndUpdate) {
      toast('downloadAndUpdateBusy'.tr, isCenter: false);
      return;
    }

    if (targetGallerys.isEmpty) {
      if (exitSelectModeAfter) {
        exitSelectMode();
      }
      return;
    }

    _isHandlingBatchDownloadAndUpdate = true;

    try {
      final Map<String, dynamic> result = await rpcRequest.requestDownloadGalleryBatchSelected(
        galleries: targetGallerys.map((gallery) => gallery.toJson()).toList(),
        config: buildBatchDownloadConfigPayload(config),
      );

      await galleryDownloadService.refreshRemoteGallerys();

      if ((result['queuedDownloadCount'] as num? ?? 0) > 0 ||
          (result['updateQueuedCount'] as num? ?? 0) > 0) {
        if (this is UpdateGlobalGalleryStatusLogicMixin) {
          (this as UpdateGlobalGalleryStatusLogicMixin).updateGlobalGalleryStatus();
        }
      }

      showBatchDownloadAndUpdateResult(
        queuedDownloadCount: (result['queuedDownloadCount'] as num? ?? 0).toInt(),
        updateQueuedCount: (result['updateQueuedCount'] as num? ?? 0).toInt(),
        failedCount: (result['failedCount'] as num? ?? 0).toInt(),
        aborted: result['aborted'] == true,
      );
    } on RPCRequestException catch (e) {
      if (e.code == -32041) {
        toast('downloadAndUpdateBusy'.tr, isCenter: false);
        return;
      }

      snack('failed'.tr, e.message, isShort: true);
    } finally {
      _isHandlingBatchDownloadAndUpdate = false;

      if (exitSelectModeAfter) {
        exitSelectMode();
      }
    }
  }

  Widget buildMultiSelectBottomBar(BuildContext context) {
    return GetBuilder<BasePageLogic>(
      id: multiSelectBottomBarId,
      global: false,
      init: this,
      builder: (_) => FadeSlideWidget(
        show: multiSelectGalleryState.inMultiSelectMode,
        axis: Axis.vertical,
        child: BottomAppBar(
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: state.gallerys.isEmpty ? null : selectAllGalleries,
                    icon: const Icon(Icons.done_all),
                    tooltip: 'multiSelect'.tr,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${'multiSelect'.tr} (${multiSelectGalleryState.selectedGids.length})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: exitSelectMode,
                    child: Text('cancel'.tr),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed:
                        multiSelectGalleryState.selectedGids.isEmpty ? null : handleBatchDownload,
                    icon: const Icon(Icons.download),
                    label: Text('download'.tr),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: multiSelectGalleryState.selectedGids.isEmpty
                        ? null
                        : handleBatchDownloadAndUpdateSelected,
                    tooltip: 'downloadAndUpdateSelected'.tr,
                    icon: const Icon(Icons.system_update_alt),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<GalleryDownloadedData?> _prepareDownloadData(
    Gallery gallery, {
    required String group,
    required bool downloadOriginalImage,
    bool showError = true,
  }) async {
    GalleryDetail? detail;

    if (gallery.pageCount == null ||
        gallery.uploader == null ||
        gallery.publishTime.isEmpty ||
        gallery.tags.isEmpty) {
      try {
        final ({GalleryDetail galleryDetails, String apikey}) detailResult =
            await ehRequest.requestDetailPage(
          galleryUrl: gallery.galleryUrl.url,
          parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey,
        );
        detail = detailResult.galleryDetails;
      } on DioException catch (e) {
        log.error('getGalleryDetailFailed'.tr, e.errorMsg);
        if (showError) {
          snack('failed'.tr, e.errorMsg ?? '', isShort: true);
        }
        return null;
      } on EHSiteException catch (e) {
        log.error('getGalleryDetailFailed'.tr, e.message);
        if (showError) {
          snack('failed'.tr, e.message, isShort: true);
        }
        return null;
      }
    }

    final GalleryDetail? galleryDetail = detail;
    final int pageCount = galleryDetail?.pageCount ?? gallery.pageCount ?? 0;

    if (pageCount <= 0) {
      log.warning('Skip download because pageCount missing. gid: ${gallery.gid}');
      return null;
    }

    final String title = galleryDetail?.japaneseTitle ?? galleryDetail?.rawTitle ?? gallery.title;
    final DateTime now = DateTime.now();

    return GalleryDownloadedData(
      gid: galleryDetail?.galleryUrl.gid ?? gallery.gid,
      token: galleryDetail?.galleryUrl.token ?? gallery.token,
      title: title,
      category: galleryDetail?.category ?? gallery.category,
      pageCount: pageCount,
      galleryUrl: galleryDetail?.galleryUrl.url ?? gallery.galleryUrl.url,
      uploader: galleryDetail?.uploader ?? gallery.uploader,
      publishTime: galleryDetail?.publishTime ?? gallery.publishTime,
      downloadStatusIndex: DownloadStatus.downloading.index,
      downloadOriginalImage: downloadOriginalImage,
      sortOrder: 0,
      groupName: group,
      insertTime: now.toString(),
      priority: GalleryDownloadService.defaultDownloadGalleryPriority,
      tags: tagMap2TagString(galleryDetail?.tags ?? gallery.tags),
      tagRefreshTime: now.toString(),
    );
  }

  Future<bool> _queueNewGalleryDownload(
    Gallery gallery, {
    required EHBatchDownloadConfig config,
  }) async {
    if (config.useArchiveForNewGalleryOnly) {
      final ArchiveDownloadedData? archiveData = await _prepareArchiveDownloadData(
        gallery,
        group: config.group,
      );

      if (archiveData != null) {
        if (!archiveDownloadService.containArchive(archiveData.gid)) {
          archiveDownloadService.downloadArchive(archiveData);
          return true;
        }

        return false;
      }
    }

    final GalleryDownloadedData? downloadData = await _prepareDownloadData(
      gallery,
      group: config.group,
      downloadOriginalImage: config.downloadOriginalImage,
      showError: false,
    );

    if (downloadData == null) {
      return false;
    }

    if (galleryDownloadService.containGallery(downloadData.gid)) {
      return false;
    }

    await galleryDownloadService.downloadGallery(downloadData);
    return true;
  }

  Future<ArchiveDownloadedData?> _prepareArchiveDownloadData(
    Gallery gallery, {
    required String group,
  }) async {
    if (!userSetting.hasLoggedIn()) {
      return null;
    }

    try {
      final ({GalleryDetail galleryDetails, String apikey}) detailResult =
          await ehRequest.requestDetailPage(
        galleryUrl: gallery.galleryUrl.url,
        parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey,
      );
      final GalleryDetail detail = detailResult.galleryDetails;
      final GalleryArchive archive = await ehRequest.get(
        url: detail.archivePageUrl,
        parser: EHSpiderParser.archivePage2Archive,
      );

      if (archive.originalSize.isEmpty) {
        return null;
      }

      final DateTime now = DateTime.now();

      return ArchiveDownloadedData(
        gid: detail.galleryUrl.gid,
        token: detail.galleryUrl.token,
        title: detail.japaneseTitle ?? detail.rawTitle,
        category: detail.category,
        pageCount: detail.pageCount,
        galleryUrl: detail.galleryUrl.url,
        uploader: detail.uploader,
        size: _computeArchiveSizeInBytes(archive.originalSize),
        coverUrl: detail.cover.url,
        publishTime: detail.publishTime,
        archiveStatusCode: ArchiveStatus.unlocking.code,
        archivePageUrl: detail.archivePageUrl,
        isOriginal: true,
        insertTime: now.toString(),
        sortOrder: 0,
        groupName: group,
        tags: tagMap2TagString(detail.tags),
        tagRefreshTime: now.toString(),
        parseSource: ArchiveParseSource.official.code,
      );
    } on DioException catch (e) {
      log.error('getGalleryArchiveFailed'.tr, e.errorMsg);
      return null;
    } on EHSiteException catch (e) {
      log.error('getGalleryArchiveFailed'.tr, e.message);
      return null;
    } catch (e, s) {
      log.error('getGalleryArchiveFailed'.tr, e, s);
      return null;
    }
  }

  int _computeArchiveSizeInBytes(String sizeString) {
    final List<String> parts = sizeString.split(' ');
    final double number = double.parse(parts[0]);
    final String unit = parts[1];

    if (unit.startsWith('K')) {
      return (number * 1024).toInt();
    }
    if (unit.startsWith('M')) {
      return (number * 1024 * 1024).toInt();
    }

    return (number * 1024 * 1024 * 1024).toInt();
  }
}
