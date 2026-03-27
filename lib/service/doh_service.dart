import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get_rx/src/rx_workers/rx_workers.dart';

import 'package:jhentai/downloader/src/model/proxy_config.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/setting/network_setting.dart';
import 'package:jhentai/utils/socks_proxy.dart';
import 'package:jhentai/utils/proxy_util.dart';

DohService dohService = DohService();

class DohService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  late final Dio _dio;
  final Map<String, _DnsCacheEntry> _cache = {};
  String _systemProxyAddress = '';

  static const Duration _defaultTtl = Duration(minutes: 5);

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
    ever(networkSetting.enableDnsOverHttps, (_) => _cache.clear());
    ever(networkSetting.dnsOverHttpsEndpoint, (_) => _cache.clear());
  }

  void _configureHttpClient() {
    final IOHttpClientAdapter adapter = _dio.httpClientAdapter as IOHttpClientAdapter;
    adapter.createHttpClient = () {
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
    };
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

    final String cacheKey = '$host-${type.name}';
    final _DnsCacheEntry? cached = _cache[cacheKey];
    if (cached != null && cached.expireAt.isAfter(DateTime.now())) {
      return cached.addresses;
    }

    try {
      final _LookupResult result = await _resolveOverHttps(host, type: type);
      if (result.addresses.isNotEmpty) {
        _cache[cacheKey] = _DnsCacheEntry(
          addresses: result.addresses,
          expireAt: DateTime.now().add(result.ttl ?? _defaultTtl),
        );
        return result.addresses;
      }
    } catch (e, stack) {
      log.error('DoH lookup failed for host: $host, reason: $e', e, stack);
    }

    return InternetAddress.lookup(host, type: type);
  }

  bool _shouldUseDoh() {
    return networkSetting.enableDnsOverHttps.value &&
        networkSetting.dnsOverHttpsEndpoint.value.trim().isNotEmpty;
  }

  Future<_LookupResult> _resolveOverHttps(
    String host, {
    InternetAddressType type = InternetAddressType.any,
  }) async {
    final String endpoint = networkSetting.dnsOverHttpsEndpoint.value.trim();
    if (endpoint.isEmpty) {
      return _LookupResult.empty();
    }

    final List<_LookupResult> results = [];
    if (type == InternetAddressType.any || type == InternetAddressType.IPv4) {
      results.add(await _query(endpoint, host, 1));
    }
    if (type == InternetAddressType.any || type == InternetAddressType.IPv6) {
      results.add(await _query(endpoint, host, 28));
    }

    final List<InternetAddress> addresses =
        results.expand((r) => r.addresses).toSet().toList(growable: false);
    if (addresses.isEmpty) {
      return _LookupResult.empty();
    }

    final Duration ttl = results.map((r) => r.ttl ?? _defaultTtl).reduce((a, b) => a < b ? a : b);
    return _LookupResult(addresses: addresses, ttl: ttl);
  }

  Future<_LookupResult> _query(String endpoint, String host, int type) async {
    final Uri base = Uri.parse(endpoint);
    final Map<String, String> queryParameters = Map.of(base.queryParameters);
    queryParameters['name'] = host;
    queryParameters['type'] = type.toString();

    final Uri uri = base.replace(queryParameters: queryParameters);
    final Response response = await _dio.getUri(
      uri,
      options: Options(
        headers: {'accept': 'application/dns-json'},
        responseType: ResponseType.json,
      ),
    );

    final dynamic data = response.data;
    if (data is! Map) {
      return _LookupResult.empty();
    }

    final int? status = (data['Status'] as num?)?.toInt();
    if (status != null && status != 0) {
      log.warning('DoH returned non-zero status: $status for host: $host');
      return _LookupResult.empty();
    }

    final List answers = data['Answer'] as List? ?? const [];
    final List<InternetAddress> addresses = [];
    int? minTtl;
    for (final dynamic answer in answers) {
      if (answer is! Map) {
        continue;
      }
      final int? typeValue = (answer['type'] as num?)?.toInt();
      if (typeValue != type) {
        continue;
      }
      final String? dataStr = answer['data'] as String?;
      if (dataStr == null) {
        continue;
      }
      final InternetAddress? address = InternetAddress.tryParse(dataStr);
      if (address == null) {
        continue;
      }
      addresses.add(address);
      final int? ttl = (answer['TTL'] as num?)?.toInt();
      if (ttl != null && ttl > 0) {
        minTtl = minTtl == null ? ttl : min(minTtl, ttl);
      }
    }

    if (addresses.isEmpty) {
      return _LookupResult.empty();
    }

    final int minTtlSeconds = minTtl == null || minTtl <= 0 ? _defaultTtl.inSeconds : minTtl;
    final Duration ttl = Duration(seconds: minTtlSeconds);

    return _LookupResult(addresses: addresses, ttl: ttl);
  }
}

class _DnsCacheEntry {
  _DnsCacheEntry({required this.addresses, required this.expireAt});

  final List<InternetAddress> addresses;
  final DateTime expireAt;
}

class _LookupResult {
  _LookupResult({required this.addresses, this.ttl});

  factory _LookupResult.empty() => _LookupResult(addresses: const []);

  final List<InternetAddress> addresses;
  final Duration? ttl;
}
