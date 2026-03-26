import 'package:dio/dio.dart';
import 'package:get/get_rx/src/rx_workers/rx_workers.dart';
import 'package:jhentai/consts/archive_bot_consts.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/network/request_retrier.dart';
import 'package:jhentai/setting/archive_bot_setting.dart';

import 'package:jhentai/service/isolate_service.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/setting/network_setting.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';

ArchiveBotRequest archiveBotRequest = ArchiveBotRequest();

class ArchiveBotRequest with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  late final Dio _dio;

  @override
  List<JHLifeCircleBean> get initDependencies =>
      super.initDependencies..addAll([ehRequest, archiveBotSetting]);

  @override
  Future<void> doInitBean() async {
    _dio = Dio(BaseOptions(
      connectTimeout: Duration(milliseconds: networkSetting.connectTimeout.value),
      receiveTimeout: Duration(milliseconds: networkSetting.receiveTimeout.value),
    ));

    ever(networkSetting.connectTimeout, (_) {
      setConnectTimeout(networkSetting.connectTimeout.value);
    });
    ever(networkSetting.receiveTimeout, (_) {
      setReceiveTimeout(networkSetting.receiveTimeout.value);
    });
  }

  @override
  Future<void> doAfterBeanReady() async {}

  void setConnectTimeout(int connectTimeout) {
    _dio.options.connectTimeout = Duration(milliseconds: connectTimeout);
  }

  void setReceiveTimeout(int receiveTimeout) {
    _dio.options.receiveTimeout = Duration(milliseconds: receiveTimeout);
  }

  Future<Response<T>> _sendWithRetry<T>({
    required Future<Response<T>> Function() send,
    required String method,
    required String url,
  }) {
    return runWithNetworkRetry(
      send: send,
      onRetry: (error, category, attempt, maxRetries) {
        log.warning(
          '[ARCHIVE-BOT] $method retry $attempt/$maxRetries '
          'reason:${retryCategoryLabel(category)} url:$url '
          'status:${error.response?.statusCode} type:${error.type}',
        );
      },
    );
  }

  Future<T> requestBalance<T>({
    String? apiAddress,
    required String apiKey,
    HtmlParser<T>? parser,
  }) async {
    final String? baseAddress =
        archiveBotSetting.useProxyServer.value ? ArchiveBotConsts.proxyServerAddress : apiAddress;
    final String url = '${baseAddress ?? ''}/balance';
    Response response = await _sendWithRetry(
      send: () => _dio.post(
        url,
        options: Options(contentType: Headers.jsonContentType),
        data: {
          'apikey': apiKey,
        },
      ),
      method: 'POST',
      url: url,
    );

    return _parseResponse(response, parser);
  }

  Future<T> requestCheckIn<T>({
    String? apiAddress,
    required String apiKey,
    HtmlParser<T>? parser,
  }) async {
    final String? baseAddress =
        archiveBotSetting.useProxyServer.value ? ArchiveBotConsts.proxyServerAddress : apiAddress;
    final String url = '${baseAddress ?? ''}/checkin';
    Response response = await _sendWithRetry(
      send: () => _dio.post(
        url,
        options: Options(contentType: Headers.jsonContentType),
        data: {
          'apikey': apiKey,
        },
      ),
      method: 'POST',
      url: url,
    );

    return _parseResponse(response, parser);
  }

  Future<T> requestResolve<T>({
    String? apiAddress,
    required String apiKey,
    required int gid,
    required String token,
    bool reParse = true,
    CancelToken? cancelToken,
    HtmlParser<T>? parser,
  }) async {
    final String? baseAddress =
        archiveBotSetting.useProxyServer.value ? ArchiveBotConsts.proxyServerAddress : apiAddress;
    final String url = '${baseAddress ?? ''}/resolve';
    Response response = await _sendWithRetry(
      send: () => _dio.post(
        url,
        options: Options(contentType: Headers.jsonContentType),
        data: {
          'apikey': apiKey,
          'gid': gid,
          'token': token,
          'force_resolve': reParse,
        },
        cancelToken: cancelToken,
      ),
      method: 'POST',
      url: url,
    );

    return _parseResponse(response, parser);
  }

  Future<T> _parseResponse<T>(Response response, HtmlParser<T>? parser) async {
    if (parser == null) {
      return response as T;
    }
    return isolateService
        .run((list) => parser(list[0], list[1]), [response.headers, response.data]);
  }
}
