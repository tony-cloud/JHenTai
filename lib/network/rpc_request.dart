import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:get/get_rx/src/rx_workers/rx_workers.dart';
import 'package:jhentai/consts/rpc_consts.dart';
import 'package:jhentai/network/request_retrier.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/setting/network_setting.dart';
import 'package:jhentai/setting/rpc_setting.dart';

RPCRequest rpcRequest = RPCRequest();

class RPCRequest with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  late final Dio _dio;
  int _requestId = 0;

  @override
  List<JHLifeCircleBean> get initDependencies =>
      super.initDependencies..addAll([networkSetting, rpcSetting]);

  @override
  Future<void> doInitBean() async {
    _dio = Dio(BaseOptions(
      connectTimeout: Duration(milliseconds: networkSetting.connectTimeout.value),
      receiveTimeout: Duration(milliseconds: networkSetting.receiveTimeout.value),
      contentType: Headers.jsonContentType,
    ));

    _dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        HttpClient client = HttpClient();
        client.badCertificateCallback = (_, __, ___) => rpcSetting.allowSelfSignedCertificate.value;
        return client;
      },
    );

    ever(networkSetting.connectTimeout, (_) {
      _dio.options.connectTimeout = Duration(milliseconds: networkSetting.connectTimeout.value);
    });

    ever(networkSetting.receiveTimeout, (_) {
      _dio.options.receiveTimeout = Duration(milliseconds: networkSetting.receiveTimeout.value);
    });
  }

  @override
  Future<void> doAfterBeanReady() async {}

  Future<Map<String, dynamic>> requestSystemHealth() {
    return request(method: RPCMethods.systemHealth);
  }

  Future<Map<String, dynamic>> requestSystemCapabilities() {
    return request(method: RPCMethods.systemCapabilities);
  }

  Future<Map<String, dynamic>> requestSetCookie({required String cookie}) {
    return request(
      method: RPCMethods.authSetCookie,
      params: {
        'cookie': cookie,
      },
    );
  }

  Future<Map<String, dynamic>> request({
    required String method,
    Map<String, dynamic>? params,
    CancelToken? cancelToken,
  }) async {
    final String url = _buildRpcUrl();
    final int requestId = _nextRequestId();

    Response response = await runWithNetworkRetry(
      send: () => _dio.post(
        url,
        options: Options(headers: _buildHeaders()),
        cancelToken: cancelToken,
        data: {
          'jsonrpc': '2.0',
          'id': requestId,
          'method': method,
          'params': params ?? const <String, dynamic>{},
        },
      ),
      onRetry: (error, category, attempt, maxRetries) {
        log.warning(
          '[RPC] POST retry $attempt/$maxRetries '
          'reason:${retryCategoryLabel(category)} url:$url '
          'status:${error.response?.statusCode} type:${error.type}',
        );
      },
    );

    final dynamic body = response.data;
    if (body is! Map) {
      throw RPCRequestException(message: 'Invalid RPC response body');
    }

    final Map<String, dynamic> payload = body.cast<String, dynamic>();
    final dynamic error = payload['error'];
    if (error is Map) {
      throw RPCRequestException(
        code: error['code'] as int?,
        message: error['message']?.toString() ?? 'Unknown RPC error',
      );
    }

    final dynamic result = payload['result'];
    if (result is! Map) {
      throw RPCRequestException(message: 'Invalid RPC result payload');
    }

    return result.cast<String, dynamic>();
  }

  Map<String, dynamic> _buildHeaders() {
    final Map<String, dynamic> headers = <String, dynamic>{};
    final String? token = rpcSetting.accessToken.value;
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  String _buildRpcUrl() {
    String address = rpcSetting.serverAddress.value;

    while (address.endsWith('/')) {
      address = address.substring(0, address.length - 1);
    }

    return '$address${RPCConsts.rpcEndpoint}';
  }

  int _nextRequestId() {
    _requestId++;
    return _requestId;
  }
}

class RPCRequestException implements Exception {
  final int? code;
  final String message;

  RPCRequestException({this.code, required this.message});

  @override
  String toString() {
    if (code == null) {
      return 'RPCRequestException: $message';
    }

    return 'RPCRequestException(code: $code, message: $message)';
  }
}
