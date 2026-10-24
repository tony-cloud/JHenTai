import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get_rx/src/rx_workers/rx_workers.dart';

import 'package:jhentai/downloader/src/model/proxy_config.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/network/doh_resolver.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/setting/network_setting.dart';
import 'package:jhentai/utils/socks_proxy.dart';
import 'package:jhentai/utils/proxy_util.dart';

DohService dohService = DohService();

class DohService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  late final Dio _dio;
  late final DohResolver _resolver;
  String _systemProxyAddress = '';

  @override
  List<JHLifeCircleBean> get initDependencies => super.initDependencies..add(networkSetting);

  @override
  Future<void> doInitBean() async {
    _dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ),
    );

    _resolver = DohResolver(dio: _dio, autoEndpoints: NetworkSetting.defaultDohEndpoints);

    if (kIsWeb) {
      return;
    }

    _systemProxyAddress = await getSystemProxyAddress();
    _configureHttpClient();
    _listenSettings();
  }

  @override
  Future<void> doAfterBeanReady() async {}

  void _listenSettings() {
    ever(networkSetting.proxyType, (_) async {
      if (networkSetting.proxyType.value == JProxyType.system) {
        _systemProxyAddress = await getSystemProxyAddress();
      }
      _configureHttpClient();
    });
    ever(networkSetting.proxyAddress, (_) => _configureHttpClient());
    ever(networkSetting.proxyUsername, (_) => _configureHttpClient());
    ever(networkSetting.proxyPassword, (_) => _configureHttpClient());
    ever(networkSetting.enableDnsOverHttps, (_) => _resolver.clear());
    ever(networkSetting.dnsOverHttpsEndpoint, (_) => _resolver.clear());
  }

  void _configureHttpClient() {
    _resolver.clear();
    _dio.httpClientAdapter.close(force: true);
    _dio.httpClientAdapter = IOHttpClientAdapter(createHttpClient: () {
      final SocksProxyConfiguration? socksConfig = _buildSocksProxyConfig();
      final HttpClient client = createProxyHttpClient(
        socksConfig: socksConfig,
      );
      if (socksConfig != null) {
        client.findProxy = (_) => 'DIRECT';
      } else if (networkSetting.proxyType.value == JProxyType.socks4) {
        client.findProxy = (_) => 'DIRECT';
      } else {
        client.findProxy = ProxyConfig.toFindProxy(_currentProxyConfig());
      }
      return client;
    });
  }

  SocksProxyConfiguration? _buildSocksProxyConfig() {
    if (networkSetting.proxyType.value != JProxyType.socks5) {
      return null;
    }

    return parseSocksProxyConfiguration(
      networkSetting.proxyAddress.value,
      username: networkSetting.proxyUsername.value,
      password: networkSetting.proxyPassword.value,
    );
  }

  ProxyConfig? _currentProxyConfig() {
    switch (networkSetting.proxyType.value) {
      case JProxyType.system:
        if (_systemProxyAddress.trim().isEmpty) {
          return null;
        }
        return ProxyConfig(
          type: ProxyType.http,
          address: _systemProxyAddress,
        );
      case JProxyType.http:
        return ProxyConfig(
          type: ProxyType.http,
          address: networkSetting.proxyAddress.value,
          username: networkSetting.proxyUsername.value,
          password: networkSetting.proxyPassword.value,
        );
      case JProxyType.socks5:
        return ProxyConfig(
          type: ProxyType.socks5,
          address: networkSetting.proxyAddress.value,
          username: networkSetting.proxyUsername.value,
          password: networkSetting.proxyPassword.value,
        );
      case JProxyType.socks4:
        return ProxyConfig(
          type: ProxyType.socks4,
          address: networkSetting.proxyAddress.value,
          username: networkSetting.proxyUsername.value,
          password: networkSetting.proxyPassword.value,
        );
      case JProxyType.direct:
        return ProxyConfig(type: ProxyType.direct, address: '');
    }
  }

  Future<List<InternetAddress>> lookup(
    String host, {
    InternetAddressType type = InternetAddressType.any,
  }) async {
    final InternetAddress? ip = InternetAddress.tryParse(host);
    if (ip != null) {
      return [ip];
    }

    if (!_shouldUseDoh()) {
      return InternetAddress.lookup(host, type: type);
    }

    try {
      return await _resolver.lookup(
        host,
        endpoint: networkSetting.dnsOverHttpsEndpoint.value,
        type: type,
      );
    } catch (e, stack) {
      log.error('DoH lookup failed for host: $host, reason: $e', e, stack);
      return InternetAddress.lookup(host, type: type);
    }
  }

  bool _shouldUseDoh() {
    return networkSetting.enableDnsOverHttps.value &&
        networkSetting.dnsOverHttpsEndpoint.value.trim().isNotEmpty;
  }
}
