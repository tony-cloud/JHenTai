import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/enum/config_enum.dart';

import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';

MouseSetting mouseSetting = MouseSetting();

class MouseSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  RxDouble wheelScrollSpeed = 5.0.obs;

  @override
  ConfigEnum get configEnum => ConfigEnum.mouseSetting;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);

    wheelScrollSpeed.value = map['wheelScrollSpeed'] ?? wheelScrollSpeed.value;
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'wheelScrollSpeed': wheelScrollSpeed.value,
    });
  }

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  Future<void> saveWheelScrollSpeed(double wheelScrollSpeed) async {
    log.debug('saveWheelScrollSpeed:$wheelScrollSpeed');
    this.wheelScrollSpeed.value = wheelScrollSpeed;
    await saveBeanConfig();
  }
}
