import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/extension/get_logic_extension.dart';
import 'package:jhentai/mixin/update_global_gallery_status_logic_mixin.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/mixin/scroll_to_top_logic_mixin.dart';
import 'package:jhentai/mixin/scroll_to_top_state_mixin.dart';
import 'package:jhentai/service/archive_download_service.dart';
import 'package:jhentai/service/local_config_service.dart';
import 'package:jhentai/setting/performance_setting.dart';
import 'package:jhentai/pages/download/mixin/archive/archive_download_page_logic_mixin.dart';
import 'package:jhentai/pages/download/mixin/archive/archive_download_page_state_mixin.dart';
import 'package:jhentai/pages/download/mixin/basic/multi_select/multi_select_download_page_logic_mixin.dart';
import 'package:jhentai/pages/download/list/archive/archive_list_download_page_state.dart';

class ArchiveListDownloadPageLogic extends GetxController
    with
        Scroll2TopLogicMixin,
        MultiSelectDownloadPageLogicMixin<ArchiveDownloadedData>,
        ArchiveDownloadPageLogicMixin,
        UpdateGlobalGalleryStatusLogicMixin {
  final String galleryId = 'galleryId';

  ArchiveListDownloadPageState state = ArchiveListDownloadPageState();

  @override
  Scroll2TopStateMixin get scroll2TopState => state;

  @override
  ArchiveDownloadPageStateMixin get archiveDownloadPageState => state;

  late Worker maxGalleryNum4AnimationListener;

  @override
  Future<void> onInit() async {
    super.onInit();

    String? displayGroupsString =
        await localConfigService.read(configKey: ConfigEnum.displayArchiveGroups);
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
    int? focusArchiveGid,
    int? focusRequestId,
    Duration focusHighlightDuration = const Duration(milliseconds: 1500),
  }) {
    if (focusArchiveGid == null ||
        focusRequestId == null ||
        state.lastFocusRequestId == focusRequestId) {
      return;
    }
    state.lastFocusRequestId = focusRequestId;
    state.focusRequestTimer?.cancel();
    // Allow the desktop tab switch and the grouped list to attach first.
    state.focusRequestTimer = Timer(const Duration(milliseconds: 220), () async {
      await state.displayGroupsCompleter.future;
      await WidgetsBinding.instance.endOfFrame;
      if (isClosed || state.lastFocusRequestId != focusRequestId) {
        return;
      }
      final String? group = archiveDownloadService.archiveDownloadInfos[focusArchiveGid]?.group;
      if (group == null || !state.groupedListController.isAttached) {
        return;
      }
      if (!state.displayGroups.contains(group)) {
        await toggleDisplayGroups(group);
        await WidgetsBinding.instance.endOfFrame;
      }
      if (isClosed ||
          state.lastFocusRequestId != focusRequestId ||
          !state.scrollController.hasClients) {
        return;
      }

      double offset = 0;
      for (final String currentGroup in archiveDownloadService.allGroups) {
        offset += UIConfig.groupListHeight + 10;
        if (!state.displayGroups.contains(currentGroup)) {
          continue;
        }
        final List<ArchiveDownloadedData> archives =
            archiveDownloadService.archivesWithGroup(currentGroup);
        if (currentGroup == group) {
          final int index = archives.indexWhere((archive) => archive.gid == focusArchiveGid);
          if (index < 0) {
            return;
          }
          offset += index * (UIConfig.downloadPageCardHeight + 10);
          break;
        }
        offset += archives.length * (UIConfig.downloadPageCardHeight + 10);
      }
      final ScrollPosition position = state.scrollController.positions.last;
      position.jumpTo(offset.clamp(position.minScrollExtent, position.maxScrollExtent).toDouble());

      final int? oldHighlightedGid = state.highlightedGid;
      state.highlightedGid = focusArchiveGid;
      state.focusHighlightTimer?.cancel();
      updateSafely([
        if (oldHighlightedGid != null) '$itemCardId::$oldHighlightedGid',
        '$itemCardId::$focusArchiveGid',
      ]);
      state.focusHighlightTimer = Timer(focusHighlightDuration, () {
        state.highlightedGid = null;
        updateSafely(['$itemCardId::$focusArchiveGid']);
      });
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
        configKey: ConfigEnum.displayArchiveGroups,
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
  void handleRemoveItem(ArchiveDownloadedData archive) {
    state.groupedListController.removeElement(archive).then((_) async {
      state.selectedGids.remove(archive.gid);
      await archiveDownloadService.deleteArchive(archive.gid);
      updateGlobalGalleryStatus();
    });
  }

  @override
  void handleResumeAllTasks() {
    archiveDownloadService.resumeAllDownloadArchive();
  }

  @override
  Future<void> selectAllItem() async {
    await state.displayGroupsCompleter.future;

    List<ArchiveDownloadedData> archives = [];
    for (String group in state.displayGroups) {
      archives.addAll(archiveDownloadService.archivesWithGroup(group));
    }

    multiSelectDownloadPageState.selectedGids.addAll(archives.map((archive) => archive.gid));
    updateSafely(
        multiSelectDownloadPageState.selectedGids.map((gid) => '$itemCardId::$gid').toList());
  }

  @override
  Future<void> changeParseSource(int gid, ArchiveParseSource parseSource) async {
    await super.changeParseSource(gid, parseSource);
    updateSafely(['$galleryId::$gid']);
  }
}
