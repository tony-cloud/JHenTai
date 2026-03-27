import 'package:dio/dio.dart';

import 'package:jhentai/network/rpc_http_client_adapter_stub.dart'
    if (dart.library.io) 'package:jhentai/network/rpc_http_client_adapter_io.dart'
    as adapter_impl;

void configureRpcHttpClientAdapter(
  Dio dio, {
  required bool allowSelfSignedCertificate,
}) {
  adapter_impl.configureRpcHttpClientAdapter(
    dio,
    allowSelfSignedCertificate: allowSelfSignedCertificate,
  );
}