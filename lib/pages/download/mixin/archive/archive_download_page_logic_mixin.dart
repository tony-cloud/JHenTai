import 'package:flutter/cupertino.dart';
import 'package:get/get.dart';
import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/extension/get_logic_extension.dart';
import 'package:jhentai/mixin/scroll_to_top_logic_mixin.dart';
import 'package:jhentai/mixin/update_global_gallery_status_logic_mixin.dart';
import 'package:jhentai/pages/base/multi_select/multi_select_batch_tag_util.dart';
import 'package:jhentai/setting/archive_bot_setting.dart';
import 'package:jhentai/setting/user_setting.dart';
import 'package:jhentai/utils/snack_util.dart';
import 'package:jhentai/widget/eh_archive_parse_source_select_dialog.dart';

import 'package:jhentai/database/database.dart';
import 'package:jhentai/model/gallery_image.dart';
import 'package:jhentai/model/read_page_info.dart';
import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/service/archive_download_service.dart';
import 'package:jhentai/service/local_config_service.dart';
import 'package:jhentai/service/super_resolution_service.dart';
import 'package:jhentai/setting/read_setting.dart';
import 'package:jhentai/setting/super_resolution_setting.dart';
import 'package:jhentai/utils/process_util.dart';
import 'package:jhentai/utils/route_util.dart';
import 'package:jhentai/utils/toast_util.dart';
import 'package:jhentai/widget/eh_alert_dialog.dart';
import 'package:jhentai/widget/eh_download_dialog.dart';
import 'package:jhentai/widget/re_unlock_dialog.dart';
import 'package:jhentai/pages/download/mixin/basic/multi_select/multi_select_download_page_logic_mixin.dart';
import 'package:jhentai/pages/download/mixin/basic/multi_select/multi_select_download_page_state_mixin.dart';
import 'package:jhentai/pages/download/mixin/archive/archive_download_page_state_mixin.dart';

mixin ArchiveDownloadPageLogicMixin on GetxController
    implements
        Scroll2TopLogicMixin,
        MultiSelectDownloadPageLogicMixin<ArchiveDownloadedData>,
        UpdateGlobalGalleryStatusLogicMixin {
  final String bodyId = 'bodyId';

  ArchiveDownloadPageStateMixin get archiveDownloadPageState;

  @override
  MultiSelectDownloadPageStateMixin get multiSelectDownloadPageState => archiveDownloadPageState;

  Future<void> handleChangeArchiveGroup(ArchiveDownloadedData archive) async {
    String oldGroup = archiveDownloadService.archiveDownloadInfos[archive.gid]!.group;

    ({String group, bool downloadOriginalImage})? result = await Get.dialog(
      EHDownloadDialog(
        title: 'changeGroup'.tr,
        currentGroup: oldGroup,
        candidates: archiveDownloadService.allGroups,
      ),
    );

    if (result == null) {
      return;
    }

    String newGroup = result.group;
    if (newGroup == oldGroup) {
      return;
    }

    await archiveDownloadService.updateArchiveGroup(archive.gid, newGroup);
    update([bodyId]);
  }

  @override
  void handleTapItem(ArchiveDownloadedData item) {
    if (multiSelectDownloadPageState.inMultiSelectMode) {
      toggleSelectItem(item.gid);
    } else {
      goToReadPage(item);
    }
  }

  @override
  void handleLongPressOrSecondaryTapItem(ArchiveDownloadedData item, BuildContext context) {
    if (multiSelectDownloadPageState.inMultiSelectMode) {
      toggleSelectItem(item.gid);
    } else {
      showBottomSheet(item, context);
    }
  }

  Future<void> handleLongPressGroup(String groupName) {
    if (archiveDownloadService.archiveDownloadInfos.values.every((a) => a.group != groupName)) {
      return handleDeleteGroup(groupName);
    }
    return handleRenameGroup(groupName);
  }

  Future<void> handleRenameGroup(String oldGroup) async {
    ({String group, bool downloadOriginalImage})? result = await Get.dialog(
      EHDownloadDialog(
        title: 'renameGroup'.tr,
        currentGroup: oldGroup,
        candidates: archiveDownloadService.allGroups,
      ),
    );

    if (result == null) {
      return;
    }

    String newGroup = result.group;
    if (newGroup == oldGroup) {
      return;
    }

    return doRenameGroup(oldGroup, newGroup);
  }

  Future<void> doRenameGroup(String oldGroup, String newGroup) async {
    await archiveDownloadService.renameGroup(oldGroup, newGroup);
    update([bodyId]);
  }

  Future<void> handleDeleteGroup(String oldGroup) async {
    bool? success = await Get.dialog(EHDialog(title: '${'deleteGroup'.tr}?'));
    if (success == null || !success) {
      return;
    }

    await archiveDownloadService.deleteGroup(oldGroup);

    update([bodyId]);
  }

  void handleResumeAllTasks() {
    archiveDownloadService.resumeAllDownloadArchive();
  }

  void handlePauseAllTasks() {
    archiveDownloadService.pauseAllDownloadArchive();
  }

  void handleRemoveItem(ArchiveDownloadedData archive) {
    archiveDownloadService.update([archiveDownloadService.galleryCountChangedId]);
  }

  Future<void> goToReadPage(ArchiveDownloadedData archive) async {
    if (archiveDownloadService.archiveDownloadInfos[archive.gid]?.archiveStatus !=
        ArchiveStatus.completed) {
      return;
    }

    if (readSetting.useThirdPartyViewer.isTrue && readSetting.thirdPartyViewerPath.value != null) {
      openThirdPartyViewer(
          archiveDownloadService.computeArchiveUnpackingPath(archive.title, archive.gid));
    } else {
      String? string = await localConfigService.read(
          configKey: ConfigEnum.readIndexRecord, subConfigKey: archive.gid.toString());
      int readIndexRecord = (string == null ? 0 : (int.tryParse(string) ?? 0));

      List<GalleryImage> images = await archiveDownloadService.getUnpackedImages(archive.gid);

      toRoute(
        Routes.read,
        arguments: ReadPageInfo(
          mode: ReadMode.archive,
          gid: archive.gid,
          galleryTitle: archive.title,
          galleryUrl: archive.galleryUrl,
          initialIndex: readIndexRecord,
          pageCount: images.length,
          isOriginal: archive.isOriginal,
          readProgressRecordStorageKey: archive.gid.toString(),
          images: images,
          useSuperResolution:
              superResolutionService.get(archive.gid, SuperResolutionType.archive) != null,
        ),
      );
    }
  }

  void showBottomSheet(ArchiveDownloadedData archive, BuildContext context) {
    ArchiveDownloadInfo? archiveDownloadInfo =
        archiveDownloadService.archiveDownloadInfos[archive.gid];

    showCupertinoModalPopup(
      context: context,
      builder: (BuildContext context) => CupertinoActionSheet(
        actions: <CupertinoActionSheetAction>[
          if (superResolutionSetting.modelDirectoryPath.value != null &&
              (superResolutionService.get(archive.gid, SuperResolutionType.archive) == null ||
                  superResolutionService.get(archive.gid, SuperResolutionType.archive)?.status ==
                      SuperResolutionStatus.paused))
            CupertinoActionSheetAction(
              child: Text('superResolution'.tr),
              onPressed: () async {
                backRoute();

                if (superResolutionService.get(archive.gid, SuperResolutionType.archive) == null &&
                    archive.isOriginal) {
                  bool? result = await Get.dialog(EHDialog(
                      title: '${'attention'.tr}!', content: 'superResolveOriginalImageHint'.tr));
                  if (result == false) {
                    return;
                  }
                }

                superResolutionService.superResolve(archive.gid, SuperResolutionType.archive);
              },
            ),
          if (superResolutionService.get(archive.gid, SuperResolutionType.archive)?.status ==
              SuperResolutionStatus.running)
            CupertinoActionSheetAction(
              child: Text('stopSuperResolution'.tr),
              onPressed: () async {
                backRoute();

                superResolutionService
                    .pauseSuperResolve(archive.gid, SuperResolutionType.archive)
                    .then((_) => toast("success".tr));
              },
            ),
          if (superResolutionService.get(archive.gid, SuperResolutionType.archive)?.status ==
                  SuperResolutionStatus.paused ||
              superResolutionService.get(archive.gid, SuperResolutionType.archive)?.status ==
                  SuperResolutionStatus.success)
            CupertinoActionSheetAction(
              child: Text('deleteSuperResolvedImage'.tr),
              onPressed: () async {
                backRoute();

                superResolutionService
                    .deleteSuperResolve(archive.gid, SuperResolutionType.archive)
                    .then((_) => toast("success".tr));
              },
            ),
          if (archiveDownloadInfo != null &&
              archiveDownloadInfo.archiveStatus.code < ArchiveStatus.downloaded.code &&
              archiveDownloadInfo.parseSource == ArchiveParseSource.bot.code)
            CupertinoActionSheetAction(
              child: Text('changeParseSource2Official'.tr),
              onPressed: () {
                backRoute();
                changeParseSource(archive.gid, ArchiveParseSource.official);
              },
            ),
          if (archiveDownloadInfo != null &&
              archiveDownloadInfo.archiveStatus.code < ArchiveStatus.downloaded.code &&
              archiveBotSetting.isReady &&
              archiveDownloadInfo.parseSource == ArchiveParseSource.official.code)
            CupertinoActionSheetAction(
              child: Text('changeParseSource2Bot'.tr),
              onPressed: () {
                backRoute();
                changeParseSource(archive.gid, ArchiveParseSource.bot);
              },
            ),
          if (archiveDownloadInfo != null &&
              archiveDownloadInfo.archiveStatus == ArchiveStatus.completed)
            CupertinoActionSheetAction(
              child: Text('migrateToDownload'.tr),
              onPressed: () async {
                backRoute();
                await handleMitigateArchiveToDownload(archive.gid);
              },
            ),
          CupertinoActionSheetAction(
            child: Text('changeGroup'.tr),
            onPressed: () {
              backRoute();
              handleChangeArchiveGroup(archive);
            },
          ),
          CupertinoActionSheetAction(
            child: Text('delete'.tr, style: TextStyle(color: UIConfig.alertColor(context))),
            onPressed: () {
              handleRemoveItem(archive);
              backRoute();
            },
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: backRoute,
          child: Text('cancel'.tr),
        ),
      ),
    );
  }

  Future<void> handleReUnlockArchive(ArchiveDownloadedData archive) async {
    bool? ok = await Get.dialog(const ReUnlockDialog());
    if (ok ?? false) {
      await archiveDownloadService.cancelArchive(archive.gid);
      await archiveDownloadService.downloadArchive(archive, resume: true, reParse: true);
    }
  }

  Future<void> handleMultiResumeTasks() async {
    for (int gid in multiSelectDownloadPageState.selectedGids) {
      archiveDownloadService.resumeDownloadArchive(gid);
    }

    exitSelectMode();
  }

  Future<void> handleMultiPauseTasks() async {
    for (int gid in multiSelectDownloadPageState.selectedGids) {
      archiveDownloadService.pauseDownloadArchive(gid);
    }

    exitSelectMode();
  }

  Future<void> handleMultiChangeGroup() async {
    ({String group, bool downloadOriginalImage})? result = await Get.dialog(
      EHDownloadDialog(
        title: 'changeGroup'.tr,
        candidates: archiveDownloadService.allGroups,
      ),
    );

    if (result == null) {
      return;
    }

    String newGroup = result.group;

    for (int gid in multiSelectDownloadPageState.selectedGids) {
      await archiveDownloadService.updateArchiveGroup(gid, newGroup);
    }

    multiSelectDownloadPageState.inMultiSelectMode = false;
    multiSelectDownloadPageState.selectedGids.clear();
    updateSafely([bottomAppbarId, bodyId]);
  }

  Future<void> handleMultiTagItems() async {
    if (!userSetting.hasLoggedIn()) {
      toast('needLoginToOperate'.tr);
      return;
    }

    final List<ArchiveDownloadedData> selectedArchives = archiveDownloadService.archives
        .where((archive) => multiSelectDownloadPageState.selectedGids.contains(archive.gid))
        .toList(growable: false);

    if (selectedArchives.isEmpty) {
      exitSelectMode();
      return;
    }

    final String? newTag = await showBatchAddTagDialog();
    if (newTag == null) {
      return;
    }

    final BatchTagResult result = await addTagToTargets(
      selectedArchives
          .map(
            (archive) => BatchTagTarget(
              gid: archive.gid,
              token: archive.token,
              galleryUrl: archive.galleryUrl,
            ),
          )
          .toList(growable: false),
      tag: newTag,
    );

    toast(
      '${'batchAddTag'.tr}: ${'success'.tr} ${result.successCount}, '
      '${'failed'.tr} ${result.failedCount}',
      isCenter: false,
    );

    if (result.failedCount > 0 && result.firstErrorMessage != null) {
      snack('failed'.tr, result.firstErrorMessage!, isShort: true);
    }

    exitSelectMode();
  }

  Future<void> handleMultiDelete() async {
    bool? result = await Get.dialog(
      EHDialog(title: 'delete'.tr, content: 'multiDeleteHint'.tr),
    );

    if (result == true) {
      List<Future> futures = [];

      for (int gid in multiSelectDownloadPageState.selectedGids) {
        futures.add(archiveDownloadService.deleteArchive(gid));
      }

      exitSelectMode();

      await Future.wait(futures);
      updateGlobalGalleryStatus();
    }
  }

  Future<void> handleMitigateArchiveToDownload(int gid) async {
    if (archiveDownloadService.isMitigationInProgress(gid)) {
      toast('operationInProgress'.tr, isCenter: false);
      return;
    }

    ArchiveMitigationReport report =
        await archiveDownloadService.mitigateCompletedOriginalArchives(gid: gid);
    _toastMitigationResult(report);
    updateGlobalGalleryStatus();
  }

  Future<void> handleMultiMitigateToDownload() async {
    int checked = 0;
    int migrated = 0;
    int replaced = 0;
    int keptOriginal = 0;
    int skipped = 0;
    int failed = 0;

    for (int gid in multiSelectDownloadPageState.selectedGids) {
      ArchiveMitigationReport report =
          await archiveDownloadService.mitigateCompletedOriginalArchives(gid: gid);
      checked += report.checked;
      migrated += report.migrated;
      replaced += report.replaced;
      keptOriginal += report.keptOriginal;
      skipped += report.skipped;
      failed += report.failed;
    }

    _toastMitigationResult(
      (
        checked: checked,
        migrated: migrated,
        replaced: replaced,
        keptOriginal: keptOriginal,
        skipped: skipped,
        failed: failed,
      ),
    );

    exitSelectMode();
    updateGlobalGalleryStatus();
  }

  void _toastMitigationResult(ArchiveMitigationReport report) {
    toast(
      'mitigateArchiveToDownloadResult'.trParams(
        {
          'checked': '${report.checked}',
          'migrated': '${report.migrated}',
          'replaced': '${report.replaced}',
          'kept': '${report.keptOriginal}',
          'skipped': '${report.skipped}',
          'failed': '${report.failed}',
        },
      ),
      isCenter: false,
    );
  }

  Future<void> handleChangeParseSource() async {
    ArchiveParseSource? result = await Get.dialog(const EHArchiveParseSourceSelectDialog());

    if (result == null) {
      return;
    }

    for (int gid in multiSelectDownloadPageState.selectedGids) {
      await archiveDownloadService.changeParseSource(gid, result);
    }

    multiSelectDownloadPageState.inMultiSelectMode = false;
    multiSelectDownloadPageState.selectedGids.clear();
    updateSafely([bottomAppbarId, bodyId]);
  }

  Future<void> changeParseSource(int gid, ArchiveParseSource parseSource) async {
    return archiveDownloadService.changeParseSource(gid, parseSource);
  }
}
