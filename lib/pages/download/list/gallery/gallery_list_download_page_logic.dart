import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/extension/get_logic_extension.dart';
import 'package:jhentai/pages/download/filter/download_filter.dart';
import 'package:jhentai/pages/download/mixin/gallery/gallery_download_page_logic_mixin.dart';
import 'package:jhentai/service/download_filter_service.dart';
import 'package:jhentai/setting/performance_setting.dart';
import 'package:jhentai/setting/style_setting.dart';

import 'package:jhentai/database/database.dart';
import 'package:jhentai/mixin/scroll_to_top_logic_mixin.dart';
import 'package:jhentai/mixin/scroll_to_top_state_mixin.dart';
import 'package:jhentai/mixin/update_global_gallery_status_logic_mixin.dart';
import 'package:jhentai/service/local_config_service.dart';
import 'package:jhentai/widget/eh_alert_dialog.dart';
import 'package:jhentai/pages/download/mixin/basic/multi_select/multi_select_download_page_logic_mixin.dart';
import 'package:jhentai/pages/download/mixin/basic/multi_select/multi_select_download_page_state_mixin.dart';
import 'package:jhentai/pages/download/widget/download_filter_dialog.dart';
import 'package:jhentai/pages/download/list/gallery/gallery_list_download_page_state.dart';

class GalleryListDownloadPageLogic extends GetxController
    with
        Scroll2TopLogicMixin,
        MultiSelectDownloadPageLogicMixin<GalleryDownloadedData>,
        GalleryDownloadPageLogicMixin,
        UpdateGlobalGalleryStatusLogicMixin {
  GalleryListDownloadPageState state = GalleryListDownloadPageState();

  @override
  MultiSelectDownloadPageStateMixin get multiSelectDownloadPageState => state;

  @override
  Scroll2TopStateMixin get scroll2TopState => state;

  late Worker maxGalleryNum4AnimationListener;

  @override
  Future<void> onInit() async {
    super.onInit();

    if (downloadService.usesRemoteRpcData) {
      await downloadService.refreshRemoteGallerys();
    }

    String? displayGroupsString =
        await localConfigService.read(configKey: ConfigEnum.displayGalleryGroups);
    if (displayGroupsString == null) {
      state.displayGroups = {'default'.tr};
    } else {
      state.displayGroups = Set.from(jsonDecode(displayGroupsString));
    }
    state.displayGroupsCompleter.complete();

    maxGalleryNum4AnimationListener =
        ever(performanceSetting.maxGalleryNum4Animation, (_) => updateSafely([bodyId]));
  }

  @override
  void onClose() {
    super.onClose();

    maxGalleryNum4AnimationListener.dispose();
    state.focusRequestTimer?.cancel();
    state.focusHighlightTimer?.cancel();
  }

  void applyFocusRequest({
    int? focusGalleryGid,
    int? focusRequestId,
    Duration focusHighlightDuration = const Duration(milliseconds: 1500),
  }) {
    if (focusGalleryGid == null || focusRequestId == null) {
      return;
    }

    if (state.lastFocusRequestId == focusRequestId) {
      return;
    }

    state.lastFocusRequestId = focusRequestId;
    state.pendingFocusGid = focusGalleryGid;
    state.focusHighlightDuration = focusHighlightDuration;

    _schedulePendingFocusRequest();
  }

  void _schedulePendingFocusRequest() {
    state.focusRequestTimer?.cancel();

    final Duration delay =
        styleSetting.isInMobileLayout ? Duration.zero : const Duration(milliseconds: 220);

    state.focusRequestTimer = Timer(delay, () {
      if (isClosed) {
        return;
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (isClosed) {
          return;
        }

        _consumePendingFocusRequest();
      });
    });
  }

  Future<void> _consumePendingFocusRequest() async {
    if (state.focusInProgress || state.pendingFocusGid == null) {
      return;
    }

    state.focusInProgress = true;

    try {
      await state.displayGroupsCompleter.future;

      final int gid = state.pendingFocusGid!;

      state.visibleGallerys = computeVisibleGallerys();
      GalleryDownloadedData? targetGallery;
      for (final GalleryDownloadedData gallery in state.visibleGallerys) {
        if (gallery.gid == gid) {
          targetGallery = gallery;
          break;
        }
      }

      if (targetGallery == null) {
        state.pendingFocusGid = null;
        return;
      }

      final String? group = downloadService.galleryDownloadInfos[gid]?.group;
      if (group == null) {
        state.pendingFocusGid = null;
        return;
      }

      if (!state.displayGroups.contains(group)) {
        await toggleDisplayGroups(group);
      }

      await Future<void>.delayed(const Duration(milliseconds: 32));

      final List<String> visibleGroups = computeVisibleGroups(state.visibleGallerys);
      final double offset = _computeScrollOffsetForGid(gid, visibleGroups);
      await _scrollToOffset(offset);

      _applyHighlight(gid);
      state.pendingFocusGid = null;
    } finally {
      state.focusInProgress = false;
    }
  }

  double _computeScrollOffsetForGid(int gid, List<String> visibleGroups) {
    final double groupExtent = UIConfig.groupListHeight + 10;
    final double itemExtent = UIConfig.downloadPageCardHeight + 10;

    final Map<String, int> groupCount = <String, int>{};
    String? targetGroup;
    int targetIndexInGroup = -1;

    for (final GalleryDownloadedData gallery in state.visibleGallerys) {
      final String? group = downloadService.galleryDownloadInfos[gallery.gid]?.group;
      if (group == null) {
        continue;
      }

      final int nextCount = (groupCount[group] ?? 0) + 1;
      groupCount[group] = nextCount;

      if (gallery.gid == gid) {
        targetGroup = group;
        targetIndexInGroup = nextCount - 1;
      }
    }

    double offset = 0;

    for (final String group in visibleGroups) {
      offset += groupExtent;

      if (group == targetGroup) {
        if (state.displayGroups.contains(group) && targetIndexInGroup >= 0) {
          offset += targetIndexInGroup * itemExtent;
        }
        return offset;
      }

      if (state.displayGroups.contains(group)) {
        offset += (groupCount[group] ?? 0) * itemExtent;
      }
    }

    return offset;
  }

  Future<void> _scrollToOffset(double offset) async {
    for (int i = 0; i < 4; i++) {
      if (state.scrollController.hasClients) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }

    if (!state.scrollController.hasClients) {
      return;
    }

    final ScrollPosition position = state.scrollController.positions.last;
    final double targetOffset =
        offset.clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();

    if ((position.pixels - targetOffset).abs() < 0.5) {
      return;
    }

    position.jumpTo(targetOffset);
  }

  void _applyHighlight(int gid) {
    final int? oldHighlightedGid = state.highlightedGid;
    state.highlightedGid = gid;

    state.focusHighlightTimer?.cancel();

    updateSafely([
      if (oldHighlightedGid != null && oldHighlightedGid != gid) '$itemCardId::$oldHighlightedGid',
      '$itemCardId::$gid',
    ]);

    state.focusHighlightTimer = Timer(state.focusHighlightDuration, () {
      if (state.highlightedGid != gid) {
        return;
      }

      state.highlightedGid = null;
      updateSafely(['$itemCardId::$gid']);
    });
  }

  Future<void> toggleDisplayGroups(String groupName) async {
    await state.displayGroupsCompleter.future;

    if (state.displayGroups.contains(groupName)) {
      state.displayGroups.remove(groupName);
    } else {
      state.displayGroups.add(groupName);
    }

    await localConfigService.write(
        configKey: ConfigEnum.displayGalleryGroups,
        value: jsonEncode(state.displayGroups.toList()));
    state.groupedListController.toggleGroup(groupName);
  }

  @override
  Future<void> doRenameGroup(String oldGroup, String newGroup) async {
    await state.displayGroupsCompleter.future;

    state.displayGroups.remove(oldGroup);
    return super.doRenameGroup(oldGroup, newGroup);
  }

  @override
  void handleRemoveItem(
      GalleryDownloadedData gallery, bool deleteImages, BuildContext context) async {
    bool isUpdatingDependent = downloadService.isUpdatingDependent(gallery.gid);

    if (isUpdatingDependent) {
      bool? result = await showDialog(
        context: context,
        builder: (_) => EHDialog(
          title: '${'delete'.tr}?',
          content: 'deleteUpdatingDependentHint'.tr,
        ),
      );
      if (result == null || !result) {
        return;
      }
    }

    state.groupedListController.removeElement(gallery).then((_) {
      state.selectedGids.remove(gallery.gid);
      downloadService.deleteGallery(gallery, deleteImages: deleteImages);
      updateGlobalGalleryStatus();
    });
  }

  @override
  Future<void> selectAllItem() async {
    await state.displayGroupsCompleter.future;

    for (GalleryDownloadedData gallery in state.visibleGallerys) {
      String? group = downloadService.galleryDownloadInfos[gallery.gid]?.group;
      if (group != null && state.displayGroups.contains(group)) {
        multiSelectDownloadPageState.selectedGids.add(gallery.gid);
      }
    }
    updateSafely(
        multiSelectDownloadPageState.selectedGids.map((gid) => '$itemCardId::$gid').toList());
  }

  List<GalleryDownloadedData> computeVisibleGallerys() {
    return downloadFilterService.filterGalleries(downloadService.gallerys);
  }

  List<String> computeVisibleGroups(List<GalleryDownloadedData> visibleGallerys) {
    final Set<String> groups = downloadFilterService.visibleGroups(visibleGallerys);
    return downloadService.allGroups.where(groups.contains).toList();
  }

  int visibleGalleryCount(String groupName) {
    int count = 0;
    for (GalleryDownloadedData gallery in state.visibleGallerys) {
      if (downloadService.galleryDownloadInfos[gallery.gid]?.group == groupName) {
        count++;
      }
    }
    return count;
  }

  Future<void> handleTapFilterButton(BuildContext context) async {
    DownloadFilter? result = await showDownloadFilterDialog(
      context: context,
      initialFilter: downloadFilterService.currentFilter,
      availableGroups: downloadService.allGroups,
    );
    if (result == null) {
      return;
    }

    await downloadFilterService.applyFilter(result);
    updateSafely([bodyId]);
  }
}
