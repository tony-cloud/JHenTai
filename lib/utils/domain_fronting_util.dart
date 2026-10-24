import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:jhentai/network/eh_ip_provider.dart';
import 'package:jhentai/service/doh_service.dart';
import 'package:jhentai/setting/network_setting.dart';

class DomainFrontingResult {
  const DomainFrontingResult({
    required this.url,
    this.originalHost,
    this.ip,
  });

  final String url;
  final String? originalHost;
  final String? ip;

  bool get applied => originalHost != null && ip != null;

  Map<String, String>? get headers => applied ? <String, String>{'host': originalHost!} : null;
}

class DomainFrontingUtil {
  DomainFrontingUtil._();

  static const String requestExtraKey = 'JHDF';
  static final EHIpProvider _ipProvider = RoundRobinIpProvider(NetworkSetting.host2IPs);
  static final Map<String, List<String>> _resolvedIPs = {};
  static final Set<String> _issuedIPs = {};
  static final Map<String, EHIpProvider> _resolvedProviders = {};

  static Future<RequestOptions> buildRequest(RequestOptions options) async {
    final DomainFrontingResult fronting = await build(options.uri.toString());
    if (!fronting.applied) {
      return options;
    }
    return options.copyWith(
      path: fronting.url,
      queryParameters: {},
      headers: {...options.headers, ...fronting.headers!},
      extra: {
        ...options.extra,
        requestExtraKey: {'host': fronting.originalHost, 'ip': fronting.ip},
      },
    );
  }

  static String requestHost(RequestOptions options) {
    final dynamic fronting = options.extra[requestExtraKey];
    return fronting is Map && fronting['host'] is String
        ? fronting['host'] as String
        : options.uri.host;
  }

  static Future<DomainFrontingResult> build(String rawUrl) {
    Uri uri;
    try {
      uri = Uri.parse(rawUrl);
    } on FormatException {
      return SynchronousFuture(DomainFrontingResult(url: rawUrl));
    }

    if (!shouldFront(uri.host)) {
      return SynchronousFuture(DomainFrontingResult(url: rawUrl));
    }
    if (!networkSetting.enableDnsOverHttps.value) {
      return SynchronousFuture(_front(uri, _ipProvider));
    }
    return _resolveAndFront(uri);
  }

  static Future<DomainFrontingResult> _resolveAndFront(Uri uri) async {
    // The resolver coalesces requests and invalidates them when settings change.
    final List<InternetAddress> addresses = await dohService.lookup(uri.host);
    final List<String> ips = addresses.map((address) => address.address).toSet().toList();
    if (ips.isEmpty) {
      throw SocketException('Failed to resolve domain fronting host: ${uri.host}');
    }
    if (!listEquals(_resolvedIPs[uri.host], ips)) {
      _resolvedIPs[uri.host] = ips;
      _resolvedProviders[uri.host] = RoundRobinIpProvider({uri.host: ips});
    }
    return _front(uri, _resolvedProviders[uri.host]!);
  }

  static DomainFrontingResult _front(Uri uri, EHIpProvider provider) {
    final String ip = provider.nextIP(uri.host);
    // Existing image providers may retry this IP after the DNS cache refreshes.
    _issuedIPs.add(ip);
    return DomainFrontingResult(
      url: uri.replace(host: ip).toString(),
      originalHost: uri.host,
      ip: ip,
    );
  }

  static bool shouldFront(String host) {
    return networkSetting.enableDomainFronting.value && _ipProvider.supports(host);
  }

  /// Fronted HTTPS requests use an IP URL with the original HTTP Host header.
  /// Permit the same certificate mismatch for resolved IPs as for stored IPs.
  static bool isFrontingIP(String ip) =>
      networkSetting.allIPs.contains(ip) || _issuedIPs.contains(ip);

  static void markUnavailable(String host, String ip) {
    if (_resolvedIPs[host]?.contains(ip) ?? false) {
      _resolvedProviders[host]?.addUnavailableIp(host, ip);
    }
    if (NetworkSetting.host2IPs[host]?.contains(ip) ?? false) {
      _ipProvider.addUnavailableIp(host, ip);
    }
  }

  static void markUnavailableFromResult(DomainFrontingResult result) {
    if (!result.applied) {
      return;
    }
    markUnavailable(result.originalHost!, result.ip!);
  }
}
