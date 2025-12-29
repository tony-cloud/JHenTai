import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/enum/config_enum.dart';

import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';

PerformanceSetting performanceSetting = PerformanceSetting();

class PerformanceSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  static const int defaultInactivateTimeoutSeconds = 600;
  static const String defaultInactivateShadeText = 'EH is running';

  RxInt maxGalleryNum4Animation = 30.obs;
  RxBool disableAllLoadingAnimations = false.obs;
  RxBool enableInactivateShade = false.obs;
  RxInt inactivateTimeoutSeconds = defaultInactivateTimeoutSeconds.obs;
  RxString inactivateShadeText = defaultInactivateShadeText.obs;

  @override
  ConfigEnum get configEnum => ConfigEnum.performanceSetting;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);

    maxGalleryNum4Animation.value = map['maxGalleryNum4Animation'] ?? maxGalleryNum4Animation.value;
    disableAllLoadingAnimations.value =
        map['disableAllLoadingAnimations'] ?? disableAllLoadingAnimations.value;
    enableInactivateShade.value = map['enableInactivateShade'] ?? enableInactivateShade.value;
    inactivateTimeoutSeconds.value =
        map['inactivateTimeoutSeconds'] ?? inactivateTimeoutSeconds.value;
    inactivateShadeText.value = map['inactivateShadeText'] ?? inactivateShadeText.value;
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'maxGalleryNum4Animation': maxGalleryNum4Animation.value,
      'disableAllLoadingAnimations': disableAllLoadingAnimations.value,
      'enableInactivateShade': enableInactivateShade.value,
      'inactivateTimeoutSeconds': inactivateTimeoutSeconds.value,
      'inactivateShadeText': inactivateShadeText.value,
    });
  }

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  Future<void> setMaxGalleryNum4Animation(int value) async {
    log.debug('setMaxGalleryNum4Animation:$value');
    maxGalleryNum4Animation.value = value;
    await saveBeanConfig();
  }

  Future<void> setDisableAllLoadingAnimations(bool value) async {
    log.debug('setDisableAllLoadingAnimations:$value');
    disableAllLoadingAnimations.value = value;
    await saveBeanConfig();
  }

  Future<void> setEnableInactivateShade(bool value) async {
    log.debug('setEnableInactivateShade:$value');
    enableInactivateShade.value = value;
    await saveBeanConfig();
  }

  Future<void> setInactivateTimeoutSeconds(int value) async {
    log.debug('setInactivateTimeoutSeconds:$value');
    inactivateTimeoutSeconds.value = value;
    await saveBeanConfig();
  }

  Future<void> setInactivateShadeText(String value) async {
    log.debug('setInactivateShadeText:$value');
    inactivateShadeText.value = value;
    await saveBeanConfig();
  }
}
