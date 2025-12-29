import 'dart:math';

import 'package:get/get.dart';
import 'package:jhentai/extension/get_logic_extension.dart';
import 'package:jhentai/mixin/scroll_to_top_logic_mixin.dart';
import 'package:jhentai/mixin/update_global_gallery_status_logic_mixin.dart';
import 'package:jhentai/model/gallery_url.dart';
import 'package:jhentai/pages/details/details_page_logic.dart';
import 'package:jhentai/pages/download/mixin/archive/archive_download_page_state_mixin.dart';
import 'package:jhentai/service/archive_download_service.dart';

import 'package:jhentai/database/database.dart';
import 'package:jhentai/mixin/scroll_to_top_state_mixin.dart';
import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/utils/route_util.dart';
import 'package:jhentai/utils/toast_util.dart';
import 'package:jhentai/pages/download/mixin/archive/archive_download_page_logic_mixin.dart';
import 'package:jhentai/pages/download/mixin/basic/multi_select/multi_select_download_page_logic_mixin.dart';
import 'package:jhentai/pages/download/grid/mixin/grid_download_page_logic_mixin.dart';
import 'package:jhentai/pages/download/grid/mixin/grid_download_page_service_mixin.dart';
import 'package:jhentai/pages/download/grid/mixin/grid_download_page_state_mixin.dart';
import 'package:jhentai/pages/download/grid/archive/archive_grid_download_page_state.dart';

class ArchiveGridDownloadPageLogic extends GetxController
    with
        Scroll2TopLogicMixin,
        MultiSelectDownloadPageLogicMixin<ArchiveDownloadedData>,
        ArchiveDownloadPageLogicMixin,
        GridBasePageLogic,
        UpdateGlobalGalleryStatusLogicMixin {
  final ArchiveGridDownloadPageState state = ArchiveGridDownloadPageState();

  @override
  Scroll2TopStateMixin get scroll2TopState => state;

  @override
  GridBasePageState get gridBasePageState => state;

  @override
  ArchiveDownloadPageStateMixin get archiveDownloadPageState => state;

  @override
  GridBasePageServiceMixin get galleryService => archiveDownloadService;

  void handleTapTitle(ArchiveDownloadedData archive) {
    if (multiSelectDownloadPageState.inMultiSelectMode) {
      toggleSelectItem(archive.gid);
    } else {
      goToDetailPage(archive);
    }
  }

  @override
  Future<void> handleRemoveItem(ArchiveDownloadedData archive) async {
    await archiveDownloadService
        .deleteArchive(archive.gid)
        .then((_) => super.handleRemoveItem(archive));
    updateGlobalGalleryStatus();
  }

  void goToDetailPage(ArchiveDownloadedData archive) {
    toRoute(
      Routes.details,
      arguments: DetailsPageArgument(galleryUrl: GalleryUrl.parse(archive.galleryUrl)),
    );
  }

  @override
  void toggleEditMode() {
    if (!gridBasePageState.inEditMode) {
      exitSelectMode();
      toast('drag2sort'.tr);
    }
    gridBasePageState.inEditMode = !gridBasePageState.inEditMode;
    update([bodyId, editButtonId]);
  }

  @override
  void selectAllItem() {
    multiSelectDownloadPageState.selectedGids.clear();
    multiSelectDownloadPageState.selectedGids
        .addAll(state.currentGalleryObjects.map((archive) => archive.gid));
    updateSafely(
        multiSelectDownloadPageState.selectedGids.map((gid) => '$itemCardId::$gid').toList());
  }

  @override
  Future<void> saveGalleryOrderAfterDrag(int beforeIndex, int afterIndex) async {
    List<ArchiveDownloadedData> archives = state.currentGalleryObjects.cast();

    /// default order is 0, we must assign current order to the archive first
    for (int i = 0; i < archives.length; i++) {
      ArchiveDownloadedData archive = archives[i];
      ArchiveDownloadInfo archiveDownloadInfo =
          archiveDownloadService.archiveDownloadInfos[archive.gid]!;
      archiveDownloadInfo.sortOrder = i;
    }

    int head = min(beforeIndex, afterIndex);
    int tail = max(beforeIndex, afterIndex);

    for (int index = head; index <= tail; index++) {
      ArchiveDownloadInfo archiveDownloadInfo =
          archiveDownloadService.archiveDownloadInfos[archives[index].gid]!;

      if (index == beforeIndex) {
        archiveDownloadInfo.sortOrder = afterIndex;
      } else if (beforeIndex < afterIndex) {
        archiveDownloadInfo.sortOrder = index - 1;
      } else {
        archiveDownloadInfo.sortOrder = index + 1;
      }
    }

    await archiveDownloadService.batchUpdateArchiveInDatabase(archives);
  }

  @override
  Future<void> saveGroupOrderAfterDrag(int beforeIndex, int afterIndex) {
    return archiveDownloadService.updateGroupOrder(beforeIndex, afterIndex);
  }

  @override
  Future<void> changeParseSource(int gid, ArchiveParseSource parseSource) async {
    await super.changeParseSource(gid, parseSource);
    updateSafely(['${super.galleryId}::$gid']);
  }
}
