import 'dart:convert';

import 'package:get/get.dart';

import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';

FtpServerSetting ftpServerSetting = FtpServerSetting();

class FtpServerSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  static const int defaultPort = 2121;
  static const int defaultPassivePoolSize = 4;
  static const int defaultPassiveTimeoutSeconds = 30;
  static const int defaultPassivePortRangeStart = 50000;
  static const int defaultPassivePortRangeEnd = 50100;

  late RxInt port;
  late RxString username;
  late RxString password;
  RxBool enableServer = false.obs;
  RxBool allowReadAndWrite = false.obs;
  RxBool keepScreenOn = false.obs;
  late RxInt passivePoolSize;
  late RxInt passiveTimeoutSeconds;
  late RxInt passivePortRangeStart;
  late RxInt passivePortRangeEnd;

  @override
  ConfigEnum get configEnum => ConfigEnum.ftpServerSetting;

  @override
  Future<void> doInitBean() async {
    port = defaultPort.obs;
    username = ''.obs;
    password = ''.obs;
    passivePoolSize = defaultPassivePoolSize.obs;
    passiveTimeoutSeconds = defaultPassiveTimeoutSeconds.obs;
    passivePortRangeStart = defaultPassivePortRangeStart.obs;
    passivePortRangeEnd = defaultPassivePortRangeEnd.obs;
  }

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);

    port.value = map['port'] ?? port.value;
    username.value = map['username'] ?? username.value;
    password.value = map['password'] ?? password.value;
    enableServer.value = map['enableServer'] ?? enableServer.value;
    allowReadAndWrite.value = map['allowReadAndWrite'] ?? allowReadAndWrite.value;
    keepScreenOn.value = map['keepScreenOn'] ?? keepScreenOn.value;
    passivePoolSize.value = map['passivePoolSize'] ?? passivePoolSize.value;
    passiveTimeoutSeconds.value = map['passiveTimeoutSeconds'] ?? passiveTimeoutSeconds.value;
    passivePortRangeStart.value = map['passivePortRangeStart'] ?? passivePortRangeStart.value;
    passivePortRangeEnd.value = map['passivePortRangeEnd'] ?? passivePortRangeEnd.value;
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'port': port.value,
      'username': username.value,
      'password': password.value,
      'enableServer': enableServer.value,
      'allowReadAndWrite': allowReadAndWrite.value,
      'keepScreenOn': keepScreenOn.value,
      'passivePoolSize': passivePoolSize.value,
      'passiveTimeoutSeconds': passiveTimeoutSeconds.value,
      'passivePortRangeStart': passivePortRangeStart.value,
      'passivePortRangeEnd': passivePortRangeEnd.value,
    });
  }

  @override
  Future<void> doAfterBeanReady() async {}

  Future<void> savePort(int port) async {
    log.debug('saveFtpPort:$port');
    this.port.value = port;
    await saveBeanConfig();
  }

  Future<void> saveUsername(String username) async {
    log.debug('saveFtpUsername:$username');
    this.username.value = username;
    await saveBeanConfig();
  }

  Future<void> savePassword(String password) async {
    log.debug('saveFtpPassword:${password.isEmpty ? '(empty)' : '***'}');
    this.password.value = password;
    await saveBeanConfig();
  }

  Future<void> saveEnableServer(bool enable) async {
    log.debug('saveFtpEnableServer:$enable');
    enableServer.value = enable;
    await saveBeanConfig();
  }

  Future<void> saveAllowReadAndWrite(bool allow) async {
    log.debug('saveFtpAllowReadAndWrite:$allow');
    allowReadAndWrite.value = allow;
    await saveBeanConfig();
  }

  Future<void> saveKeepScreenOn(bool keepScreenOn) async {
    log.debug('saveFtpKeepScreenOn:$keepScreenOn');
    this.keepScreenOn.value = keepScreenOn;
    await saveBeanConfig();
  }

  Future<void> savePassivePoolSize(int poolSize) async {
    log.debug('saveFtpPassivePoolSize:$poolSize');
    passivePoolSize.value = poolSize;
    await saveBeanConfig();
  }

  Future<void> savePassiveTimeoutSeconds(int seconds) async {
    log.debug('saveFtpPassiveTimeoutSeconds:$seconds');
    passiveTimeoutSeconds.value = seconds;
    await saveBeanConfig();
  }

  Future<void> savePassivePortRange({required int start, required int end}) async {
    log.debug('saveFtpPassivePortRange:$start-$end');
    passivePortRangeStart.value = start;
    passivePortRangeEnd.value = end;
    await saveBeanConfig();
  }
}
