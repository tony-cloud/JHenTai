import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/config/jh_api_secret_config.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/service/log.dart';

import 'package:jhentai/consts/archive_bot_consts.dart';
import 'package:jhentai/service/jh_service.dart';

ArchiveBotSetting archiveBotSetting = ArchiveBotSetting();

class ArchiveBotSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  final bool hasJHServer;

  ArchiveBotSetting({this.hasJHServer = JHApiSecretConfig.secret != ''});

  final RxnString apiAddress = RxnString(ArchiveBotConsts.serverAddress);
  final RxnString apiKey = RxnString(null);
  final RxBool useProxyServer = false.obs;

  final RxBool preferBotSource = false.obs;
  final RxBool hideArchiveBot = true.obs;

  bool get isVisible => hasJHServer && hideArchiveBot.isFalse;

  bool get isReady =>
      hasJHServer &&
      (apiAddress.value != null || useProxyServer.isTrue) &&
      apiKey.value != null;

  @override
  ConfigEnum get configEnum => ConfigEnum.archiveBotSetting;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);
    apiAddress.value = map['apiAddress'] ?? apiAddress.value;
    apiKey.value = map['apiKey'];
    preferBotSource.value = map['preferBotSource'] ?? false;
    hideArchiveBot.value = map['hideArchiveBot'] ?? true;
    useProxyServer.value = map['useProxyServer'] ?? true;
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'apiAddress': apiAddress.value,
      'apiKey': apiKey.value,
      'preferBotSource': preferBotSource.value,
      'hideArchiveBot': hideArchiveBot.value,
      'useProxyServer': useProxyServer.value,
    });
  }

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  Future<void> saveAllConfig(String? address, String? key, bool useProxy) async {
    log.debug('saveAllConfig: $address, $key, $useProxy');
    apiAddress.value = address;
    apiKey.value = key;
    useProxyServer.value = useProxy;
    await saveBeanConfig();
  }

  Future<void> saveApiAddress(String? value) async {
    log.debug('saveApiAddress: $value');
    apiAddress.value = value;
    await saveBeanConfig();
  }

  Future<void> saveApiKey(String? value) async {
    log.debug('saveApiKey: $value');
    apiKey.value = value;
    await saveBeanConfig();
  }

  Future<void> savePreferBotSource(bool value) async {
    preferBotSource.value = value;
    await saveBeanConfig();
  }

  Future<void> saveHideArchiveBot(bool value) async {
    hideArchiveBot.value = value;
    await saveBeanConfig();
  }

  Future<void> saveUseProxyServer(bool value) async {
    log.debug('saveUseProxyServer: $value');
    useProxyServer.value = value;
    await saveBeanConfig();
  }
}
