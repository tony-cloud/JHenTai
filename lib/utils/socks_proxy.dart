import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:socks5_proxy/socks_client.dart';

part 'network_transport.dart';

typedef LookupCallback = Future<List<InternetAddress>> Function(
  String host, {
  InternetAddressType type,
});

/// Supplies alternate origin addresses for an already-routed URL. Returning
/// null retains normal DNS resolution. TLS always uses the URL authority.
typedef ConnectionAddressProvider = Future<List<InternetAddress>?> Function(
    Uri uri);

typedef SocksProxyConfigProvider = SocksProxyConfiguration? Function();

class SocksProxy {
  SocksProxy._();

  static void refreshAddressPolicy() {
    _managedClients.removeWhere((reference) => reference.target == null);
    for (final reference in _managedClients.toList()) {
      reference.target?._refreshAddressPolicy();
    }
  }

  static void initProxy({
    String? proxy,
    void Function(HttpClient client)? onCreate,
    String Function(Uri url)? findProxy,
    SocksProxyConfigProvider? socksConfig,
    LookupCallback? lookup,
    bool Function()? enableIPv6,
    ConnectionAddressProvider? connectionAddresses,
  }) {
    HttpOverrides.global = _ProxyOverrides(
      onCreate: onCreate,
      findProxy: findProxy,
      socksConfig: socksConfig,
      lookup: lookup,
      enableIPv6: enableIPv6,
      connectionAddresses: connectionAddresses,
    );
  }
}

HttpClient createProxyHttpClient({
  SecurityContext? context,
  SocksProxyConfiguration? socksConfig,
  LookupCallback? lookup,
  bool Function()? enableIPv6,
  ConnectionAddressProvider? connectionAddresses,
}) {
  final client = HttpOverrides.runWithHttpOverrides(
    () => HttpClient(context: context),
    _PassthroughHttpOverrides(),
  );
  return _TransportHttpClient(
      client, context, lookup, enableIPv6, socksConfig, connectionAddresses);
}

class SocksProxyConfiguration {
  const SocksProxyConfiguration({
    required this.host,
    required this.port,
    this.username,
    this.password,
  });

  final String host;
  final int port;
  final String? username;
  final String? password;
}

SocksProxyConfiguration? parseSocksProxyConfiguration(
  String? rawAddress, {
  String? username,
  String? password,
}) {
  if (rawAddress == null || rawAddress.trim().isEmpty) {
    return null;
  }

  final String addressWithScheme =
      rawAddress.contains('://') ? rawAddress : 'socks://$rawAddress';

  final Uri? uri = Uri.tryParse(addressWithScheme);
  if (uri == null ||
      (uri.host.isEmpty && uri.authority.isEmpty) ||
      uri.port == 0) {
    return null;
  }

  final String host = uri.host.isNotEmpty ? uri.host : uri.authority;
  final List<String> userInfoParts = uri.userInfo.split(':');
  final String? parsedUsername =
      uri.userInfo.isEmpty ? username : userInfoParts.first;
  final String? parsedPassword = uri.userInfo.isEmpty
      ? password
      : (userInfoParts.length > 1 ? userInfoParts[1] : null);

  return SocksProxyConfiguration(
    host: host,
    port: uri.port,
    username: _normalize(parsedUsername ?? username),
    password: _normalize(parsedPassword ?? password),
  );
}

class _PassthroughHttpOverrides extends HttpOverrides {}

class _ProxyOverrides extends HttpOverrides {
  _ProxyOverrides(
      {this.onCreate,
      this.findProxy,
      this.socksConfig,
      this.lookup,
      this.enableIPv6,
      this.connectionAddresses});

  final void Function(HttpClient client)? onCreate;
  final String Function(Uri url)? findProxy;
  final SocksProxyConfigProvider? socksConfig;
  final LookupCallback? lookup;
  final bool Function()? enableIPv6;
  final ConnectionAddressProvider? connectionAddresses;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = _TransportHttpClient(super.createHttpClient(context),
        context, lookup, enableIPv6, socksConfig?.call(), connectionAddresses);
    if (findProxy != null && client._socks == null) {
      client.findProxy = findProxy;
    }
    onCreate?.call(client);
    return client;
  }
}

String? _normalize(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
