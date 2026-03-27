import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

void configureRpcHttpClientAdapter(
  Dio dio, {
  required bool allowSelfSignedCertificate,
}) {
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      HttpClient client = HttpClient();
      client.badCertificateCallback = (_, __, ___) => allowSelfSignedCertificate;
      return client;
    },
  );
}
