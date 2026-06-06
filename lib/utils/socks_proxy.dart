import 'dart:io';

import 'package:socks5_proxy/socks_client.dart';

typedef LookupCallback = Future<List<InternetAddress>> Function(
  String host, {
  InternetAddressType type,
});

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
    LookupCallback? lookup,
  }) {
    if (lookup != null) {
      IOOverrides.global = _LookupOverrides(lookup);
    }
    HttpOverrides.global = _ProxyOverrides(
      onCreate: onCreate,
      findProxy: findProxy,
      socksConfig: socksConfig,
      lookupCallback: lookup,
    );
  }
}

HttpClient createProxyHttpClient({
  SecurityContext? context,
  SocksProxyConfiguration? socksConfig,
  LookupCallback? lookup,
}) {
  final HttpClient client = lookup == null
      ? HttpOverrides.runWithHttpOverrides(
          () => HttpClient(context: context),
          _PassthroughHttpOverrides(),
        )
      : IOOverrides.runWithIOOverrides(
          () => HttpOverrides.runWithHttpOverrides(
            () => HttpClient(context: context),
            _PassthroughHttpOverrides(lookupCallback: lookup),
          ),
          _LookupOverrides(lookup),
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
    this.lookupCallback,
  });

  final void Function(HttpClient client)? onCreate;
  final String Function(Uri url)? findProxy;
  final SocksProxyConfigProvider? socksConfig;
  final LookupCallback? lookupCallback;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    HttpClient build() {
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

    if (lookupCallback == null) {
      return build();
    }

    return IOOverrides.runWithIOOverrides(
      build,
      _LookupOverrides(lookupCallback!),
    );
  }
}

class _PassthroughHttpOverrides extends HttpOverrides {
  _PassthroughHttpOverrides({this.lookupCallback});

  final LookupCallback? lookupCallback;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // This is a passthrough HttpClient that does not modify requests.
    if (lookupCallback == null) {
      return super.createHttpClient(context);
    }

    return IOOverrides.runWithIOOverrides(
      () => super.createHttpClient(context),
      _LookupOverrides(lookupCallback!),
    );
  }
}

final class _LookupOverrides extends IOOverrides {
  _LookupOverrides(this.lookupCallback);

  final LookupCallback lookupCallback;

  @override
  Future<Socket> socketConnect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
    Duration? timeout,
  }) async {
    final InternetAddress resolved = await _resolveHost(host);
    return super.socketConnect(
      resolved,
      port,
      sourceAddress: sourceAddress,
      sourcePort: sourcePort,
      timeout: timeout,
    );
  }

  @override
  Future<ConnectionTask<Socket>> socketStartConnect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
  }) async {
    final InternetAddress resolved = await _resolveHost(host);
    return super.socketStartConnect(
      resolved,
      port,
      sourceAddress: sourceAddress,
      sourcePort: sourcePort,
    );
  }

  Future<InternetAddress> _resolveHost(Object host) async {
    if (host is InternetAddress) {
      return host;
    }

    final List<InternetAddress> addresses = await lookupCallback(
      host.toString(),
      type: InternetAddressType.any,
    );
    if (addresses.isEmpty) {
      throw SocketException(
        'Failed to resolve host',
        address: host is InternetAddress ? host : null,
        port: null,
      );
    }
    return addresses.first;
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
