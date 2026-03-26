import 'package:dio/dio.dart';
import 'package:get/get_rx/src/rx_workers/rx_workers.dart';
import 'package:jhentai/config/jh_api_secret_config.dart';
import 'package:jhentai/consts/jh_consts.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/network/request_retrier.dart';
import 'package:jhentai/utils/hmac_util.dart';

import 'package:jhentai/service/isolate_service.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/setting/network_setting.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';

JHRequest jhRequest = JHRequest();

class JHRequest with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  late final Dio _dio;

  @override
  List<JHLifeCircleBean> get initDependencies => super.initDependencies..add(ehRequest);

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
          '[JHREQ] $method retry $attempt/$maxRetries '
          'reason:${retryCategoryLabel(category)} url:$url '
          'status:${error.response?.statusCode} type:${error.type}',
        );
      },
    );
  }

  Future<T> requestAlive<T>({HtmlParser<T>? parser}) async {
    final String url = '${JHConsts.serverAddress}/alive';
    Response response = await _sendWithRetry(
      send: () => _dio.get(url),
      method: 'GET',
      url: url,
    );

    return _parseResponse(response, parser);
  }

  Future<T> requestListConfig<T>({int? type, HtmlParser<T>? parser}) async {
    final String url = '${JHConsts.serverAddress}/api/config/list';
    Response response = await _sendWithRetry(
      send: () => _dio.get(
        url,
        queryParameters: {
          if (type != null) 'type': type,
        },
      ),
      method: 'GET',
      url: url,
    );

    return _parseResponse(response, parser);
  }

  Future<T> requestConfigByShareCode<T>({required String shareCode, HtmlParser<T>? parser}) async {
    final String url = '${JHConsts.serverAddress}/api/config/getByShareCode';
    Response response = await _sendWithRetry(
      send: () => _dio.get(
        url,
        queryParameters: {
          'shareCode': shareCode,
        },
      ),
      method: 'GET',
      url: url,
    );

    return _parseResponse(response, parser);
  }

  Future<T> requestBatchUploadConfig<T>({
    required List<({int type, String version, String config})> configs,
    HtmlParser<T>? parser,
  }) async {
    final String url = '${JHConsts.serverAddress}/api/config/upload';
    Response response = await _sendWithRetry(
      send: () => _dio.post(
        url,
        options: Options(contentType: Headers.jsonContentType),
        data: {
          'configs': configs
              .map((c) => {
                    'type': c.type,
                    'version': c.version,
                    'config': c.config,
                  })
              .toList(),
        },
      ),
      method: 'POST',
      url: url,
    );

    return _parseResponse(response, parser);
  }

  Future<T> requestDeleteConfig<T>({required int id, HtmlParser<T>? parser}) async {
    final String url = '${JHConsts.serverAddress}/api/config/delete';
    Response response = await _sendWithRetry(
      send: () => _dio.post(
        url,
        queryParameters: {
          'id': id,
        },
      ),
      method: 'POST',
      url: url,
    );

    return _parseResponse(response, parser);
  }

  Future<T> requestGalleryImageHashes<T>({
    required int gid,
    required String token,
    CancelToken? cancelToken,
    HtmlParser<T>? parser,
  }) async {
    String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final String url = '${JHConsts.serverAddress}/api/gallery/fetchImageHash';

    Response response = await _sendWithRetry(
      send: () => _dio.get(
        url,
        queryParameters: {'gid': gid, 'token': token},
        options: Options(
          contentType: Headers.jsonContentType,
          headers: {
            JHConsts.APP_ID_HEADER: JHConsts.APP_ID,
            JHConsts.TIMESTAMP_HEADER: timestamp,
            JHConsts.NONCE_HEADER: timestamp,
            JHConsts.SIGNATURE_HEADER: HmacUtil.hmacSha256(
                '${JHConsts.APP_ID}-$timestamp-$timestamp', JHApiSecretConfig.secret),
          },
        ),
        cancelToken: cancelToken,
      ),
      method: 'GET',
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
