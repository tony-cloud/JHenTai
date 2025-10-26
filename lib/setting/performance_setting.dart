import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/enum/config_enum.dart';

import '../service/jh_service.dart';
import '../service/log.dart';

PerformanceSetting performanceSetting = PerformanceSetting();

class PerformanceSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  RxInt maxGalleryNum4Animation = 30.obs;
  RxBool disableAllLoadingAnimations = false.obs;

  @override
  ConfigEnum get configEnum => ConfigEnum.performanceSetting;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);

    maxGalleryNum4Animation.value = map['maxGalleryNum4Animation'] ?? maxGalleryNum4Animation.value;
    disableAllLoadingAnimations.value =
        map['disableAllLoadingAnimations'] ?? disableAllLoadingAnimations.value;
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'maxGalleryNum4Animation': maxGalleryNum4Animation.value,
      'disableAllLoadingAnimations': disableAllLoadingAnimations.value,
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
}
