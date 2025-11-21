import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/extension/dio_exception_extension.dart';
import 'package:jhentai/extension/get_logic_extension.dart';
import 'package:jhentai/model/gallery.dart';
import 'package:jhentai/model/gallery_detail.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/setting/download_setting.dart';
import 'package:jhentai/setting/user_setting.dart';
import 'package:jhentai/utils/convert_util.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';
import 'package:jhentai/utils/snack_util.dart';
import 'package:jhentai/utils/toast_util.dart';
import 'package:jhentai/widget/eh_download_dialog.dart';
import 'package:jhentai/widget/fade_slide_widget.dart';

import '../../../exception/eh_site_exception.dart';
import '../../../mixin/update_global_gallery_status_logic_mixin.dart';
import '../base_page_logic.dart';
import 'multi_select_gallery_state_mixin.dart';

mixin MultiSelectGalleryLogicMixin on BasePageLogic {
  MultiSelectGalleryStateMixin get multiSelectGalleryState;

  final String multiSelectBottomBarId = 'multiSelectBottomBarId';

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
        snack('failed'.tr, e.errorMsg ?? '', isShort: true);
        return null;
      } on EHSiteException catch (e) {
        log.error('getGalleryDetailFailed'.tr, e.message);
        snack('failed'.tr, e.message, isShort: true);
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
}
