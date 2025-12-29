import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/scheduler.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_navigation/get_navigation.dart';
import 'package:get/get_rx/get_rx.dart';
import 'package:get/get_utils/get_utils.dart';
import 'package:jhentai/database/dao/archive_dao.dart';
import 'package:jhentai/database/dao/gallery_dao.dart';
import 'package:jhentai/extension/dio_exception_extension.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/setting/archive_bot_setting.dart';
import 'package:jhentai/setting/network_setting.dart';
import 'package:jhentai/setting/preference_setting.dart';
import 'package:jhentai/setting/user_setting.dart';
import 'package:jhentai/utils/convert_util.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';
import 'package:jhentai/utils/snack_util.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:retry/retry.dart';

import 'package:jhentai/database/database.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/model/archive_bot_response/archive_bot_response.dart';
import 'package:jhentai/model/archive_bot_response/check_in_vo.dart';
import 'package:jhentai/model/gallery_metadata.dart';
import 'package:jhentai/network/archive_bot_request.dart';
import 'package:jhentai/setting/advanced_setting.dart';
import 'package:jhentai/utils/archive_bot_response_parser.dart';
import 'package:jhentai/utils/version_util.dart';
import 'package:jhentai/widget/update_dialog.dart';
import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/local_config_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/utils/cookie_util.dart';
import 'package:jhentai/utils/route_util.dart';

ScheduleService scheduleService = ScheduleService();

class ScheduleService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  @override
  Future<void> doInitBean() async {}

  @override
  Future<void> doAfterBeanReady() async {
    Timer(const Duration(seconds: 3), _checkUpdate);
    Timer(const Duration(seconds: 10), refreshGalleryTags);
    Timer(const Duration(seconds: 10), refreshArchiveTags);
    Timer(const Duration(seconds: 5), clearOutdatedImageCache);
    Timer(const Duration(seconds: 1), _clearOutdatedGalleryImageHashCache);

    Timer(const Duration(seconds: 5), checkEHEvent);
    Timer.periodic(const Duration(minutes: 5), (_) => checkEHEvent());

    Timer(const Duration(seconds: 5), checkInArchiveBot);
    Timer.periodic(const Duration(minutes: 5), (_) => checkInArchiveBot());
  }

  Future<void> _checkUpdate() async {
    if (advancedSetting.enableCheckUpdate.isFalse) {
      return;
    }

    String url = 'https://api.github.com/repos/jiangtian616/JHenTai/releases';
    String latestVersion;

    try {
      latestVersion = (await retry(
        () => ehRequest.get(url: url, parser: EHSpiderParser.githubReleasePage2LatestVersion),
        maxAttempts: 3,
      ))
          .trim()
          .split('+')[0];
    } on Exception catch (_) {
      log.info('check update failed');
      return;
    }

    String? dismissVersion = await localConfigService.read(configKey: ConfigEnum.dismissVersion);
    if (dismissVersion == latestVersion) {
      return;
    }

    PackageInfo packageInfo = await PackageInfo.fromPlatform();
    String currentVersion = 'v${packageInfo.version}'.trim();
    log.info(
        'Latest version:[$latestVersion], current version: [$currentVersion], current build: [${packageInfo.buildNumber}]');

    if (compareVersion(currentVersion, latestVersion) >= 0) {
      return;
    }

    SchedulerBinding.instance.addPostFrameCallback((_) {
      Get.dialog(UpdateDialog(currentVersion: currentVersion, latestVersion: latestVersion));
    });
  }

  Future<void> refreshGalleryTags({bool ignoreSetting = false}) async {
    if (!ignoreSetting && advancedSetting.enableRefreshGalleryTags.isFalse) {
      return;
    }
    int pageNo = 1;
    List<GalleryDownloadedData> gallerys = await GalleryDao.selectGallerysForTagRefresh(pageNo, 25);
    while (gallerys.isNotEmpty) {
      try {
        List<GalleryMetadata> metadatas =
            await ehRequest.requestGalleryMetadatas<List<GalleryMetadata>>(
          list: gallerys.map((a) => (gid: a.gid, token: a.token)).toList(),
          parser: EHSpiderParser.galleryMetadataJson2GalleryMetadatas,
        );

        await GalleryDao.batchUpdateGallery(
          metadatas
              .map(
                (m) => GalleryDownloadedCompanion(
                  gid: Value(m.galleryUrl.gid),
                  tags: Value(tagMap2TagString(m.tags)),
                  tagRefreshTime: Value(DateTime.now().toString()),
                ),
              )
              .toList(),
        );
        log.trace(
            'refreshGalleryTags success, pageNo: $pageNo, archives: ${gallerys.map((a) => a.gid).toList()}');
      } catch (e) {
        log.warning(
            'refreshGalleryTags error, gallerys: ${gallerys.map((a) => (
                  gid: a.gid,
                  token: a.token
                )).toList()}',
            e,
            true);
      }

      pageNo++;
      gallerys = await GalleryDao.selectGallerysForTagRefresh(pageNo, 25);
    }
  }

  Future<void> refreshArchiveTags({bool ignoreSetting = false}) async {
    if (!ignoreSetting && advancedSetting.enableRefreshArchiveTags.isFalse) {
      return;
    }
    int pageNo = 1;
    List<ArchiveDownloadedData> archives = await ArchiveDao.selectArchivesForTagRefresh(pageNo, 25);
    while (archives.isNotEmpty) {
      try {
        List<GalleryMetadata> metadatas =
            await ehRequest.requestGalleryMetadatas<List<GalleryMetadata>>(
          list: archives.map((a) => (gid: a.gid, token: a.token)).toList(),
          parser: EHSpiderParser.galleryMetadataJson2GalleryMetadatas,
        );

        await ArchiveDao.batchUpdateArchive(
          metadatas
              .map(
                (m) => ArchiveDownloadedCompanion(
                  gid: Value(m.galleryUrl.gid),
                  tags: Value(tagMap2TagString(m.tags)),
                  tagRefreshTime: Value(DateTime.now().toString()),
                ),
              )
              .toList(),
        );
        log.trace(
            'refreshArchiveTags success, pageNo: $pageNo, archives: ${archives.map((a) => a.gid).toList()}');
      } catch (e) {
        log.warning(
            'refreshArchiveTags error, archives: ${archives.map((a) => a.gid).toList()}', e, true);
      }

      pageNo++;
      archives = await ArchiveDao.selectArchivesForTagRefresh(pageNo, 25);
    }
  }

  Future<void> clearOutdatedImageCache() async {
    Directory cacheImageDirectory =
        Directory(join((await getTemporaryDirectory()).path, cacheImageFolderName));

    int count = 0;
    cacheImageDirectory.list().forEach((FileSystemEntity entity) {
      if (entity is File &&
          DateTime.now().difference(entity.lastAccessedSync()) >
              networkSetting.cacheImageExpireDuration.value) {
        entity.delete();
        count++;
      }
    }).then((_) => log.info('Clear outdated image cache success, count: $count'));
  }

  Future<void> _clearOutdatedGalleryImageHashCache() async {
    DateTime thresholdTime = DateTime.now().subtract(const Duration(days: 3));
    String thresholdTimeStr = thresholdTime.toString();

    return appDb.managers.localConfig
        .filter((config) =>
            config.configKey.equals(ConfigEnum.galleryImageHash.key) &
            config.utime.column.isSmallerThanValue(thresholdTimeStr))
        .delete()
        .then((value) => value > 0);
  }

  Future<void> checkEHEvent() async {
    if (!userSetting.hasLoggedIn()) {
      return;
    }

    if (preferenceSetting.showHVInfo.isFalse && preferenceSetting.showDawnInfo.isFalse) {
      return;
    }

    ({String? dawnInfo, String? hvUrl}) eventInfo;
    try {
      eventInfo = await retry(
        () => ehRequest.requestNews(EHSpiderParser.newsPage2Event),
        retryIf: (e) => e is DioException,
        maxAttempts: 3,
      );
    } catch (e) {
      log.warning('ScheduleService checkDawn failed', e);
      return;
    }

    if (preferenceSetting.showDawnInfo.isTrue && eventInfo.dawnInfo != null) {
      log.info('Check dawn success: ${eventInfo.dawnInfo}');
      snack(
        'dawnOfaNewDay'.tr,
        eventInfo.dawnInfo!,
        isShort: false,
      );
    }

    if (preferenceSetting.showHVInfo.isTrue && eventInfo.hvUrl != null) {
      log.info('Encounter a monster: ${eventInfo.hvUrl}');
      snack(
        'encounterMonster'.tr,
        'encounterMonsterHint'.tr,
        onPressed: () {
          toRoute(
            Routes.webviewFullscreen,
            arguments: {
              'title': 'openHentaiVerse'.tr,
              'url': eventInfo.hvUrl!,
              'cookies': CookieUtil.parse2String(ehRequest.cookies),
            },
            preventDuplicates: false,
          );
        },
        isShort: false,
      );
    }
  }

  Future<void> checkInArchiveBot() async {
    if (!archiveBotSetting.isReady) {
      return;
    }

    try {
      ArchiveBotResponse response = await archiveBotRequest.requestCheckIn(
        apiAddress: archiveBotSetting.apiAddress.value,
        apiKey: archiveBotSetting.apiKey.value!,
        parser: ArchiveBotResponseParser.commonParse,
      );
      log.debug('Auto Checkin response: $response');
      if (response.isSuccess) {
        CheckInVO checkInVO = CheckInVO.fromResponse(response.data);
        snack(
            'checkInSuccess'.tr,
            'checkInSuccessHint'
                .trArgs([checkInVO.getGP.toString(), checkInVO.currentGP.toString()]));
      }
    } on DioException catch (e) {
      log.error('Failed to auto checkin', e.errorMsg, e.stackTrace);
    } catch (e) {
      log.error('Failed to auto checkin', e.toString(), StackTrace.current);
    }
  }
}
