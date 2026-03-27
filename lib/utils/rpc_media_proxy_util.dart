import 'package:flutter/foundation.dart';
import 'package:jhentai/consts/rpc_consts.dart';
import 'package:jhentai/setting/rpc_setting.dart';

class RPCMediaProxyResult {
  const RPCMediaProxyResult({
    required this.url,
    this.headers,
    this.proxied = false,
  });

  final String url;
  final Map<String, String>? headers;
  final bool proxied;
}

class RPCMediaProxyUtil {
  RPCMediaProxyUtil._();

  static RPCMediaProxyResult build(String rawUrl) {
    final Uri? uri = Uri.tryParse(rawUrl);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return RPCMediaProxyResult(url: rawUrl);
    }

    if (!kIsWeb || !rpcSetting.enableRpcMode.value) {
      return RPCMediaProxyResult(url: rawUrl);
    }

    final String serverAddress = _normalizeServerAddress(rpcSetting.serverAddress.value);
    if (serverAddress.isEmpty) {
      return RPCMediaProxyResult(url: rawUrl);
    }

    final Uri? serverUri = Uri.tryParse(serverAddress);
    if (serverUri != null &&
        uri.scheme == serverUri.scheme &&
        uri.host == serverUri.host &&
        uri.port == serverUri.port &&
        (uri.path == RPCConsts.rpcMediaEndpoint ||
            uri.path == RPCConsts.rpcDownloadedGalleryImageEndpoint)) {
      return RPCMediaProxyResult(
        url: rawUrl,
        headers: _buildAuthHeaders(),
      );
    }

    final Uri mediaUri = Uri.parse('$serverAddress${RPCConsts.rpcMediaEndpoint}')
        .replace(queryParameters: <String, String>{'url': rawUrl});

    return RPCMediaProxyResult(
      url: mediaUri.toString(),
      headers: _buildAuthHeaders(),
      proxied: true,
    );
  }

  static Map<String, String>? _buildAuthHeaders() {
    final String? token = rpcSetting.accessToken.value?.trim();
    return token == null || token.isEmpty
        ? null
        : <String, String>{'Authorization': 'Bearer $token'};
  }

  static String _normalizeServerAddress(String serverAddress) {
    String value = serverAddress.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }
}
