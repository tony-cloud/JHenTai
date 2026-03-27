import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';

RpcSetting rpcSetting = RpcSetting();

class RpcSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  RxBool enableRpcMode = false.obs;
  RxString serverAddress = 'https://127.0.0.1:3210'.obs;
  Rx<RPCServerProfile> serverProfile = RPCServerProfile.local.obs;
  RxnString accessToken = RxnString();
  RxBool allowSelfSignedCertificate = false.obs;

  static const Map<RPCServerProfile, String> profilePresets = {
    RPCServerProfile.local: 'https://127.0.0.1:3210',
    RPCServerProfile.lan: 'https://192.168.1.100:3210',
    RPCServerProfile.cloud: 'https://rpc.example.com',
  };

  @override
  ConfigEnum get configEnum => ConfigEnum.rpcSetting;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);

    enableRpcMode.value = map['enableRpcMode'] ?? enableRpcMode.value;
    serverAddress.value = _normalizeServerAddress(map['serverAddress'] ?? serverAddress.value);
    serverProfile.value =
        RPCServerProfile.values[map['serverProfile'] ?? serverProfile.value.index];
    accessToken.value = map['accessToken'] ?? accessToken.value;
    allowSelfSignedCertificate.value =
        map['allowSelfSignedCertificate'] ?? allowSelfSignedCertificate.value;
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'enableRpcMode': enableRpcMode.value,
      'serverAddress': serverAddress.value,
      'serverProfile': serverProfile.value.index,
      'accessToken': accessToken.value,
      'allowSelfSignedCertificate': allowSelfSignedCertificate.value,
    });
  }

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  Future<void> saveEnableRpcMode(bool enableRpcMode) async {
    log.debug('saveEnableRpcMode:$enableRpcMode');
    this.enableRpcMode.value = enableRpcMode;
    await saveBeanConfig();
  }

  Future<void> saveServerAddress(String serverAddress) async {
    log.debug('saveServerAddress:$serverAddress');
    this.serverAddress.value = _normalizeServerAddress(serverAddress);
    if (!profilePresets.containsValue(this.serverAddress.value)) {
      serverProfile.value = RPCServerProfile.custom;
    }
    await saveBeanConfig();
  }

  Future<void> saveServerProfile(RPCServerProfile serverProfile) async {
    log.debug('saveServerProfile:$serverProfile');
    this.serverProfile.value = serverProfile;

    if (serverProfile != RPCServerProfile.custom) {
      serverAddress.value = profilePresets[serverProfile]!;
    }

    await saveBeanConfig();
  }

  Future<void> saveAccessToken(String? accessToken) async {
    log.debug('saveAccessToken:${accessToken == null ? 'null' : '******'}');
    this.accessToken.value = accessToken;
    await saveBeanConfig();
  }

  Future<void> saveAllowSelfSignedCertificate(
    bool allowSelfSignedCertificate,
  ) async {
    log.debug('saveAllowSelfSignedCertificate:$allowSelfSignedCertificate');
    this.allowSelfSignedCertificate.value = allowSelfSignedCertificate;
    await saveBeanConfig();
  }

  String _normalizeServerAddress(String serverAddress) {
    String value = serverAddress.trim();

    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }

    return value;
  }
}

enum RPCServerProfile {
  local,
  lan,
  cloud,
  custom,
}
