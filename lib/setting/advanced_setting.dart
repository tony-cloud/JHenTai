import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/service/log.dart';
import 'package:logger/logger.dart';

import '../service/jh_service.dart';

AdvancedSetting advancedSetting = AdvancedSetting();

class AdvancedSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  RxBool enableLogging = true.obs;
  RxBool enableVerboseLogging = kDebugMode.obs;
  Rx<Level> logLevel = Level.debug.obs;
  RxBool enableCheckUpdate = true.obs;
  RxBool enableCheckClipboard = true.obs;
  RxBool inNoImageMode = false.obs;
  RxBool enableRefreshGalleryTags = true.obs;
  RxBool enableRefreshArchiveTags = true.obs;

  @override
  ConfigEnum get configEnum => ConfigEnum.advancedSetting;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);

    enableLogging.value = map['enableLogging'];
    enableVerboseLogging.value = map['enableVerboseLogging'] ?? enableVerboseLogging.value;
    int? levelIndex = map['logLevelIndex'];
    if (levelIndex != null && levelIndex >= 0 && levelIndex < Level.values.length) {
      logLevel.value = Level.values[levelIndex];
    }
    enableCheckUpdate.value = map['enableCheckUpdate'] ?? enableCheckUpdate.value;
    enableCheckClipboard.value = map['enableCheckClipboard'] ?? enableCheckClipboard.value;
    inNoImageMode.value = map['inNoImageMode'] ?? inNoImageMode.value;
    enableRefreshGalleryTags.value =
        map['enableRefreshGalleryTags'] ?? enableRefreshGalleryTags.value;
    enableRefreshArchiveTags.value =
        map['enableRefreshArchiveTags'] ?? enableRefreshArchiveTags.value;
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'enableLogging': enableLogging.value,
      'enableVerboseLogging': enableVerboseLogging.value,
      'logLevelIndex': logLevel.value.index,
      'enableCheckUpdate': enableCheckUpdate.value,
      'enableCheckClipboard': enableCheckClipboard.value,
      'inNoImageMode': inNoImageMode.value,
      'enableRefreshGalleryTags': enableRefreshGalleryTags.value,
      'enableRefreshArchiveTags': enableRefreshArchiveTags.value,
    });
  }

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  Future<void> saveEnableLogging(bool enableLogging) async {
    log.debug('saveEnableLogging:$enableLogging');
    this.enableLogging.value = enableLogging;
    await saveBeanConfig();
  }

  Future<void> saveEnableVerboseLogging(bool enableVerboseLogging) async {
    log.debug('saveEnableVerboseLogging:$enableVerboseLogging');
    this.enableVerboseLogging.value = enableVerboseLogging;
    await saveBeanConfig();
  }

  Future<void> saveLogLevel(Level level) async {
    log.debug('saveLogLevel:$level');
    logLevel.value = level;
    await saveBeanConfig();
  }

  Future<void> saveEnableCheckUpdate(bool enableCheckUpdate) async {
    log.debug('saveEnableCheckUpdate:$enableCheckUpdate');
    this.enableCheckUpdate.value = enableCheckUpdate;
    await saveBeanConfig();
  }

  Future<void> saveEnableCheckClipboard(bool enableCheckClipboard) async {
    log.debug('saveEnableCheckClipboard:$enableCheckClipboard');
    this.enableCheckClipboard.value = enableCheckClipboard;
    await saveBeanConfig();
  }

  Future<void> saveInNoImageMode(bool inNoImageMode) async {
    log.debug('saveInNoImageMode:$inNoImageMode');
    this.inNoImageMode.value = inNoImageMode;
    await saveBeanConfig();
  }

  Future<void> saveEnableRefreshGalleryTags(bool enableRefreshGalleryTags) async {
    log.debug('saveEnableRefreshGalleryTags:$enableRefreshGalleryTags');
    this.enableRefreshGalleryTags.value = enableRefreshGalleryTags;
    await saveBeanConfig();
  }

  Future<void> saveEnableRefreshArchiveTags(bool enableRefreshArchiveTags) async {
    log.debug('saveEnableRefreshArchiveTags:$enableRefreshArchiveTags');
    this.enableRefreshArchiveTags.value = enableRefreshArchiveTags;
    await saveBeanConfig();
  }
}
