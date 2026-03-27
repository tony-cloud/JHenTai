import 'dart:convert';
import 'dart:math';

import 'package:get/get.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';

RpcSetting rpcSetting = RpcSetting();

class RpcSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  RxBool enableRpcMode = false.obs;
  RxString serverAddress = 'http://127.0.0.1:3210'.obs;
  Rx<RPCServerProfile> serverProfile = RPCServerProfile.local.obs;
  RxnString accessToken = RxnString();
  RxBool allowSelfSignedCertificate = false.obs;
  RxBool enableEmbeddedServer = false.obs;
  RxString embeddedHost = '0.0.0.0'.obs;
  RxInt embeddedPort = 3210.obs;
  RxString embeddedToken = ''.obs;

  static const Map<RPCServerProfile, String> profilePresets = {
    RPCServerProfile.local: 'http://127.0.0.1:3210',
    RPCServerProfile.lan: 'http://192.168.1.100:3210',
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
    enableEmbeddedServer.value = map['enableEmbeddedServer'] ?? enableEmbeddedServer.value;
    embeddedHost.value = map['embeddedHost'] ?? embeddedHost.value;
    embeddedPort.value = _normalizePort(map['embeddedPort'], fallback: embeddedPort.value);
    embeddedToken.value = map['embeddedToken'] ?? embeddedToken.value;

    if (enableEmbeddedServer.isTrue) {
      if (embeddedToken.value.trim().isEmpty) {
        embeddedToken.value = _generateToken();
      }

      serverProfile.value = RPCServerProfile.custom;
      serverAddress.value = _embeddedClientAddress();
      accessToken.value = embeddedToken.value;
    }

    if (GetPlatform.isWeb) {
      enableRpcMode.value = true;
      enableEmbeddedServer.value = false;
    }
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'enableRpcMode': enableRpcMode.value,
      'serverAddress': serverAddress.value,
      'serverProfile': serverProfile.value.index,
      'accessToken': accessToken.value,
      'allowSelfSignedCertificate': allowSelfSignedCertificate.value,
      'enableEmbeddedServer': enableEmbeddedServer.value,
      'embeddedHost': embeddedHost.value,
      'embeddedPort': embeddedPort.value,
      'embeddedToken': embeddedToken.value,
    });
  }

  @override
  Future<void> doInitBean() async {
    if (GetPlatform.isWeb) {
      enableRpcMode.value = true;
      enableEmbeddedServer.value = false;
    }
  }

  @override
  void doAfterBeanReady() {}

  Future<void> saveEnableRpcMode(bool enableRpcMode) async {
    if (GetPlatform.isWeb && !enableRpcMode) {
      log.warning('RPC mode cannot be disabled on web.');
      this.enableRpcMode.value = true;
      await saveBeanConfig();
      return;
    }

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

  Future<void> saveEnableEmbeddedServer(bool enabled) async {
    if (GetPlatform.isWeb && enabled) {
      log.warning('Embedded RPC server is not supported on web.');
      enableEmbeddedServer.value = false;
      await saveBeanConfig();
      return;
    }

    log.debug('saveEnableEmbeddedServer:$enabled');
    enableEmbeddedServer.value = enabled;

    if (enabled) {
      if (embeddedToken.value.trim().isEmpty) {
        embeddedToken.value = _generateToken();
      }
      enableRpcMode.value = true;
      serverProfile.value = RPCServerProfile.custom;
      serverAddress.value = _embeddedClientAddress();
      accessToken.value = embeddedToken.value;
    }

    await saveBeanConfig();
  }

  Future<void> saveEmbeddedHost(String host) async {
    final String normalizedHost = host.trim();
    if (normalizedHost.isEmpty) {
      return;
    }

    log.debug('saveEmbeddedHost:$normalizedHost');
    embeddedHost.value = normalizedHost;
    if (enableEmbeddedServer.isTrue) {
      serverAddress.value = _embeddedClientAddress();
    }
    await saveBeanConfig();
  }

  Future<void> saveEmbeddedPort(int port) async {
    final int normalizedPort = _normalizePort(port, fallback: embeddedPort.value);
    log.debug('saveEmbeddedPort:$normalizedPort');
    embeddedPort.value = normalizedPort;

    if (enableEmbeddedServer.isTrue) {
      serverAddress.value = _embeddedClientAddress();
    }

    await saveBeanConfig();
  }

  Future<void> saveEmbeddedToken(String token) async {
    final String normalizedToken = token.trim();
    if (normalizedToken.isEmpty) {
      return;
    }

    log.debug('saveEmbeddedToken:******');
    embeddedToken.value = normalizedToken;

    if (enableEmbeddedServer.isTrue) {
      accessToken.value = embeddedToken.value;
    }

    await saveBeanConfig();
  }

  Future<void> regenerateEmbeddedToken() async {
    embeddedToken.value = _generateToken();
    if (enableEmbeddedServer.isTrue) {
      accessToken.value = embeddedToken.value;
    }
    await saveBeanConfig();
  }

  String _normalizeServerAddress(String serverAddress) {
    String value = serverAddress.trim();

    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }

    return value;
  }

  int _normalizePort(dynamic value, {required int fallback}) {
    int? parsed;

    if (value is int) {
      parsed = value;
    } else if (value is String) {
      parsed = int.tryParse(value.trim());
    }

    if (parsed == null || parsed < 1 || parsed > 65535) {
      return fallback;
    }

    return parsed;
  }

  String _embeddedClientAddress() {
    return 'http://127.0.0.1:${embeddedPort.value}';
  }

  String _generateToken() {
    final Random random = Random.secure();
    const String chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

    return List<String>.generate(32, (_) => chars[random.nextInt(chars.length)]).join();
  }
}

enum RPCServerProfile {
  local,
  lan,
  cloud,
  custom,
}
