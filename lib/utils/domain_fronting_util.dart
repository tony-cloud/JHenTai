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
  // EX's public DNS points at a CDN that rejects TLS without domain SNI. Use
  // its direct origin addresses so enabling DoH does not disable fronting.
  static const staticFrontingHosts = {'exhentai.org'};
  static final _routes = <String, _FrontingRoute>{};
  static const _maxRoutes = 2048;
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
    if (!networkSetting.enableDnsOverHttps.value || staticFrontingHosts.contains(uri.host)) {
      return SynchronousFuture(_front(uri, _ipProvider, NetworkSetting.host2IPs[uri.host]!));
    }
    return _resolveAndFront(uri);
  }

  static Future<DomainFrontingResult> _resolveAndFront(Uri uri) async {
    // The resolver coalesces requests and invalidates them when settings change.
    final List<InternetAddress> addresses = await dohService.lookup(uri.host);
    final List<String> ips = addresses
        .where((address) =>
            networkSetting.enableIPv6.value || address.type == InternetAddressType.IPv4)
        .map((address) => address.address)
        .toSet()
        .toList();
    if (ips.isEmpty) {
      throw SocketException('Failed to resolve domain fronting host: ${uri.host}');
    }
    if (!listEquals(_resolvedIPs[uri.host], ips)) {
      _resolvedIPs[uri.host] = ips;
      _resolvedProviders[uri.host] = RoundRobinIpProvider({uri.host: ips});
    }
    return _front(uri, _resolvedProviders[uri.host]!, ips);
  }

  static DomainFrontingResult _front(Uri uri, EHIpProvider provider, List<String> ips) {
    final String ip = provider.nextIP(uri.host);
    // Existing image providers may retry this IP after the DNS cache refreshes.
    _issuedIPs.add(ip);
    final url = uri.replace(host: ip).toString();
    final key = Uri.parse(url).removeFragment().toString();
    final previous = _routes.remove(key);
    // A shared IP/path can represent different virtual hosts. Only retain
    // candidates common to both routes in that case.
    final candidates = previous == null || previous.host == uri.host
        ? ips
        : ips.where(previous.ips.contains).toList();
    _routes[key] = _FrontingRoute(previous == null || previous.host == uri.host ? uri.host : null,
        [ip, ...candidates.where((candidate) => candidate != ip)]);
    if (_routes.length > _maxRoutes) {
      _routes.remove(_routes.keys.first);
    }
    return DomainFrontingResult(
      url: url,
      originalHost: uri.host,
      ip: ip,
    );
  }

  /// Supplies alternate addresses without restoring hostname SNI. DoH's own
  /// HTTP client deliberately does not use this callback.
  static Future<List<InternetAddress>?> connectionAddresses(Uri uri) async {
    final key = uri.removeFragment().toString();
    final route = _routes.remove(key);
    if (route == null) {
      return null;
    }
    _routes[key] = route;
    return route.ips
        .map(InternetAddress.new)
        .where((address) =>
            networkSetting.enableIPv6.value || address.type == InternetAddressType.IPv4)
        .toList();
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

class _FrontingRoute {
  const _FrontingRoute(this.host, this.ips);
  final String? host;
  final List<String> ips;
}
