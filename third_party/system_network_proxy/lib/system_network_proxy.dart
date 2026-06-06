import 'src/system_network_proxy_stub.dart'
    if (dart.library.io) 'src/system_network_proxy_io.dart' as implementation;

class SystemNetworkProxy {
  static void init() {
    implementation.init();
  }

  static Future<bool> getProxyEnable() {
    return implementation.getProxyEnable();
  }

  static Future<bool> setProxyEnable(bool proxyEnable) {
    return implementation.setProxyEnable(proxyEnable);
  }

  static Future<String> getProxyServer() {
    return implementation.getProxyServer();
  }

  static Future<bool> setProxyServer(String proxyServer) {
    return implementation.setProxyServer(proxyServer);
  }
}
