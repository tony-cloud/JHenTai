import 'dart:io';

import 'package:socks5_proxy/socks_client.dart';

typedef SocksProxyConfigProvider = SocksProxyConfiguration? Function();

class SocksProxy {
  SocksProxy._();

  /// Initializes global HTTP overrides so every new [HttpClient] respects the
  /// configured proxy settings. Optional [findProxy] behaves like the standard
  /// `HttpClient.findProxy` callback, while [socksConfig] allows providing SOCKS
  /// specific settings that are handled through socks5_proxy.
  static void initProxy({
    String? proxy,
    void Function(HttpClient client)? onCreate,
    String Function(Uri url)? findProxy,
    SocksProxyConfigProvider? socksConfig,
  }) {
    HttpOverrides.global = _ProxyOverrides(
      onCreate: onCreate,
      findProxy: findProxy,
      socksConfig: socksConfig,
    );
  }
}

HttpClient createProxyHttpClient({
  SecurityContext? context,
  SocksProxyConfiguration? socksConfig,
}) {
  final HttpClient client = HttpOverrides.runWithHttpOverrides(
    () => HttpClient(context: context),
    _PassthroughHttpOverrides(),
  );
  if (socksConfig != null) {
    _applySocksProxy(client, socksConfig);
  }
  return client;
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

  final String addressWithScheme = rawAddress.contains('://') ? rawAddress : 'socks://$rawAddress';

  final Uri? uri = Uri.tryParse(addressWithScheme);
  if (uri == null || (uri.host.isEmpty && uri.authority.isEmpty) || uri.port == 0) {
    return null;
  }

  final String host = uri.host.isNotEmpty ? uri.host : uri.authority;
  final List<String> userInfoParts = uri.userInfo.split(':');
  final String? parsedUsername = uri.userInfo.isEmpty ? username : userInfoParts.first;
  final String? parsedPassword =
      uri.userInfo.isEmpty ? password : (userInfoParts.length > 1 ? userInfoParts[1] : null);

  return SocksProxyConfiguration(
    host: host,
    port: uri.port,
    username: _normalize(parsedUsername ?? username),
    password: _normalize(parsedPassword ?? password),
  );
}

class _ProxyOverrides extends HttpOverrides {
  _ProxyOverrides({
    this.onCreate,
    this.findProxy,
    this.socksConfig,
  });

  final void Function(HttpClient client)? onCreate;
  final String Function(Uri url)? findProxy;
  final SocksProxyConfigProvider? socksConfig;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final SocksProxyConfiguration? config = socksConfig?.call();
    final HttpClient client = super.createHttpClient(context);

    if (config != null) {
      _applySocksProxy(client, config);
      client.findProxy = (_) => 'DIRECT';
    } else if (findProxy != null) {
      client.findProxy = findProxy!;
    }

    onCreate?.call(client);
    return client;
  }
}

class _PassthroughHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

void _applySocksProxy(HttpClient client, SocksProxyConfiguration config) {
  final InternetAddress host = _toInternetAddress(config.host);
  final ProxySettings settings = ProxySettings(
    host,
    config.port,
    username: _normalize(config.username),
    password: _normalize(config.password),
  );
  SocksTCPClient.assignToHttpClient(client, [settings]);
}

InternetAddress _toInternetAddress(String host) {
  final InternetAddress? direct = InternetAddress.tryParse(host);
  if (direct != null) {
    return direct;
  }
  return InternetAddress(host);
}

String? _normalize(String? value) {
  if (value == null) {
    return null;
  }
  final String trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
