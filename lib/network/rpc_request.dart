import 'package:dio/dio.dart';
import 'package:get/get_rx/src/rx_workers/rx_workers.dart';
import 'package:jhentai/consts/rpc_consts.dart';
import 'package:jhentai/network/rpc_http_client_adapter.dart';
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

    configureRpcHttpClientAdapter(
      _dio,
      allowSelfSignedCertificate: rpcSetting.allowSelfSignedCertificate.value,
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

  Future<Map<String, dynamic>> requestSystemFetchUrl({
    required String url,
    String method = 'GET',
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Map<String, String>? headers,
    bool expectBinary = false,
  }) {
    return request(
      method: RPCMethods.systemFetchUrl,
      params: <String, dynamic>{
        'url': url,
        'method': method,
        if (queryParameters != null) 'queryParameters': queryParameters,
        if (data != null) 'data': data,
        if (headers != null) 'headers': headers,
        'expectBinary': expectBinary,
      },
    );
  }

  Future<Map<String, dynamic>> requestForumUser({required int ipbMemberId}) {
    return request(
      method: RPCMethods.forumUser,
      params: <String, dynamic>{
        'ipbMemberId': ipbMemberId,
      },
    );
  }

  Future<Map<String, dynamic>> requestSettingPage() {
    return request(method: RPCMethods.settingPage);
  }

  Future<Map<String, dynamic>> requestFavoritePopup({
    required int gid,
    required String token,
    required String act,
  }) {
    return request(
      method: RPCMethods.favoritePopup,
      params: <String, dynamic>{
        'gid': gid,
        'token': token,
        'act': act,
      },
    );
  }

  Future<Map<String, dynamic>> requestFavoritePage() {
    return request(method: RPCMethods.favoritePage);
  }

  Future<Map<String, dynamic>> requestFavoriteSort({required String inlineSet}) {
    return request(
      method: RPCMethods.favoriteSort,
      params: <String, dynamic>{
        'inlineSet': inlineSet,
      },
    );
  }

  Future<Map<String, dynamic>> requestFavoriteAdd({
    required int gid,
    required String token,
    required int favcat,
    required String note,
  }) {
    return request(
      method: RPCMethods.favoriteAdd,
      params: <String, dynamic>{
        'gid': gid,
        'token': token,
        'favcat': favcat,
        'note': note,
      },
    );
  }

  Future<Map<String, dynamic>> requestFavoriteRemove({
    required int gid,
    required String token,
  }) {
    return request(
      method: RPCMethods.favoriteRemove,
      params: <String, dynamic>{
        'gid': gid,
        'token': token,
      },
    );
  }

  Future<Map<String, dynamic>> requestTorrentPage({
    required int gid,
    required String token,
  }) {
    return request(
      method: RPCMethods.torrentPage,
      params: <String, dynamic>{
        'gid': gid,
        'token': token,
      },
    );
  }

  Future<Map<String, dynamic>> requestMyTagsPage({required int tagSetNo}) {
    return request(
      method: RPCMethods.myTagsPage,
      params: <String, dynamic>{
        'tagSetNo': tagSetNo,
      },
    );
  }

  Future<Map<String, dynamic>> requestMyTagsAdd({
    required String tag,
    String? tagColor,
    required int tagWeight,
    required bool watch,
    required bool hidden,
    required int tagSetNo,
  }) {
    return request(
      method: RPCMethods.myTagsAdd,
      params: <String, dynamic>{
        'tag': tag,
        if (tagColor != null) 'tagColor': tagColor,
        'tagWeight': tagWeight,
        'watch': watch,
        'hidden': hidden,
        'tagSetNo': tagSetNo,
      },
    );
  }

  Future<Map<String, dynamic>> requestMyTagsDelete({
    required int watchedTagId,
    required int tagSetNo,
  }) {
    return request(
      method: RPCMethods.myTagsDelete,
      params: <String, dynamic>{
        'watchedTagId': watchedTagId,
        'tagSetNo': tagSetNo,
      },
    );
  }

  Future<Map<String, dynamic>> requestMyTagsUpdateSet({
    required int tagSetNo,
    required bool enable,
    String? color,
  }) {
    return request(
      method: RPCMethods.myTagsUpdateSet,
      params: <String, dynamic>{
        'tagSetNo': tagSetNo,
        'enable': enable,
        if (color != null) 'color': color,
      },
    );
  }

  Future<Map<String, dynamic>> requestCommentVote({
    required int gid,
    required String token,
    required int apiuid,
    required String apikey,
    required int commentId,
    required bool isVotingUp,
  }) {
    return request(
      method: RPCMethods.commentVote,
      params: <String, dynamic>{
        'gid': gid,
        'token': token,
        'apiuid': apiuid,
        'apikey': apikey,
        'commentId': commentId,
        'isVotingUp': isVotingUp,
      },
    );
  }

  Future<Map<String, dynamic>> requestCommentSend({
    required String galleryUrl,
    required String content,
  }) {
    return request(
      method: RPCMethods.commentSend,
      params: <String, dynamic>{
        'galleryUrl': galleryUrl,
        'content': content,
      },
    );
  }

  Future<Map<String, dynamic>> requestCommentUpdate({
    required String galleryUrl,
    required String content,
    required int commentId,
  }) {
    return request(
      method: RPCMethods.commentUpdate,
      params: <String, dynamic>{
        'galleryUrl': galleryUrl,
        'content': content,
        'commentId': commentId,
      },
    );
  }

  Future<Map<String, dynamic>> requestRatingSubmit({
    required int gid,
    required String token,
    required int apiuid,
    required String apikey,
    required int rating,
  }) {
    return request(
      method: RPCMethods.ratingSubmit,
      params: <String, dynamic>{
        'gid': gid,
        'token': token,
        'apiuid': apiuid,
        'apikey': apikey,
        'rating': rating,
      },
    );
  }

  Future<Map<String, dynamic>> requestTagSuggestion({required String keyword}) {
    return request(
      method: RPCMethods.tagSuggestion,
      params: <String, dynamic>{
        'keyword': keyword,
      },
    );
  }

  Future<Map<String, dynamic>> requestLookupImage({
    required String imagePath,
    required String imageName,
  }) {
    return request(
      method: RPCMethods.lookupImage,
      params: <String, dynamic>{
        'imagePath': imagePath,
        'imageName': imageName,
      },
    );
  }

  Future<Map<String, dynamic>> requestArchiveUnlock({
    required String url,
    required bool isOriginal,
  }) {
    return request(
      method: RPCMethods.archiveUnlock,
      params: <String, dynamic>{
        'url': url,
        'isOriginal': isOriginal,
      },
    );
  }

  Future<Map<String, dynamic>> requestArchiveCancel({required String url}) {
    return request(
      method: RPCMethods.archiveCancel,
      params: <String, dynamic>{
        'url': url,
      },
    );
  }

  Future<Map<String, dynamic>> requestArchiveHathDownload({
    required String url,
    required String resolution,
  }) {
    return request(
      method: RPCMethods.archiveHathDownload,
      params: <String, dynamic>{
        'url': url,
        'resolution': resolution,
      },
    );
  }

  Future<Map<String, dynamic>> requestDownloadGalleryList() {
    return request(method: RPCMethods.downloadGalleryList);
  }

  Future<Map<String, dynamic>> requestDownloadGalleryImages({required int gid}) {
    return request(
      method: RPCMethods.downloadGalleryImages,
      params: <String, dynamic>{
        'gid': gid,
      },
    );
  }

  Future<Map<String, dynamic>> requestHistoryPage({
    required int pageIndex,
    required int pageSize,
  }) {
    return request(
      method: RPCMethods.historyPage,
      params: <String, dynamic>{
        'pageIndex': pageIndex,
        'pageSize': pageSize,
      },
    );
  }

  Future<Map<String, dynamic>> requestRecordHistory({
    required int gid,
    required String jsonBody,
    String? lastReadTime,
  }) {
    return request(
      method: RPCMethods.historyRecord,
      params: <String, dynamic>{
        'gid': gid,
        'jsonBody': jsonBody,
        if (lastReadTime != null) 'lastReadTime': lastReadTime,
      },
    );
  }

  Future<Map<String, dynamic>> requestDeleteHistory({required int gid}) {
    return request(
      method: RPCMethods.historyDelete,
      params: <String, dynamic>{
        'gid': gid,
      },
    );
  }

  Future<Map<String, dynamic>> requestDeleteAllHistory() {
    return request(method: RPCMethods.historyDeleteAll);
  }

  Future<Map<String, dynamic>> requestSetCookie({required String cookie}) {
    return request(
      method: RPCMethods.authSetCookie,
      params: {
        'cookie': cookie,
      },
    );
  }

  Future<Map<String, dynamic>> requestAuthLogin({
    required String userName,
    required String passWord,
  }) {
    return request(
      method: RPCMethods.authLogin,
      params: <String, dynamic>{
        'userName': userName,
        'passWord': passWord,
      },
    );
  }

  Future<Map<String, dynamic>> requestDownloadGalleryStart({
    required Map<String, dynamic> gallery,
  }) {
    return request(
      method: RPCMethods.downloadGalleryStart,
      params: <String, dynamic>{
        'gallery': gallery,
      },
    );
  }

  Future<Map<String, dynamic>> requestDownloadGalleryPause({required int gid}) {
    return request(
      method: RPCMethods.downloadGalleryPause,
      params: <String, dynamic>{
        'gid': gid,
      },
    );
  }

  Future<Map<String, dynamic>> requestDownloadGalleryResume({required int gid}) {
    return request(
      method: RPCMethods.downloadGalleryResume,
      params: <String, dynamic>{
        'gid': gid,
      },
    );
  }

  Future<Map<String, dynamic>> requestDownloadGalleryDelete({
    required int gid,
    required bool deleteImages,
  }) {
    return request(
      method: RPCMethods.downloadGalleryDelete,
      params: <String, dynamic>{
        'gid': gid,
        'deleteImages': deleteImages,
      },
    );
  }

  Future<Map<String, dynamic>> requestDownloadGalleryAssignPriority({
    required int gid,
    required int priority,
  }) {
    return request(
      method: RPCMethods.downloadGalleryAssignPriority,
      params: <String, dynamic>{
        'gid': gid,
        'priority': priority,
      },
    );
  }

  Future<Map<String, dynamic>> requestDownloadGalleryPauseAll() {
    return request(method: RPCMethods.downloadGalleryPauseAll);
  }

  Future<Map<String, dynamic>> requestDownloadGalleryResumeAll() {
    return request(method: RPCMethods.downloadGalleryResumeAll);
  }

  Future<Map<String, dynamic>> requestDownloadGalleryCleanupDuplicates() {
    return request(method: RPCMethods.downloadGalleryCleanupDuplicates);
  }

  Future<Map<String, dynamic>> requestDownloadGalleryClearParentCache() {
    return request(method: RPCMethods.downloadGalleryClearParentCache);
  }

  Future<Map<String, dynamic>> requestDownloadGalleryBatchSelected({
    required List<Map<String, dynamic>> galleries,
    required Map<String, dynamic> config,
    CancelToken? cancelToken,
  }) {
    return request(
      method: RPCMethods.downloadGalleryBatchSelected,
      cancelToken: cancelToken,
      params: <String, dynamic>{
        'galleries': galleries,
        'config': config,
      },
    );
  }

  Future<Map<String, dynamic>> requestDownloadGalleryBatchFavorite({
    required Map<String, dynamic> searchConfig,
    required Map<String, dynamic> config,
    CancelToken? cancelToken,
  }) {
    return request(
      method: RPCMethods.downloadGalleryBatchFavorite,
      cancelToken: cancelToken,
      params: <String, dynamic>{
        'searchConfig': searchConfig,
        'config': config,
      },
    );
  }

  Future<Map<String, dynamic>> requestDownloadGalleryBatchStatus() {
    return request(method: RPCMethods.downloadGalleryBatchStatus);
  }

  Future<Map<String, dynamic>> requestDownloadGalleryBatchAbort() {
    return request(method: RPCMethods.downloadGalleryBatchAbort);
  }

  Future<Map<String, dynamic>> requestDownloadArchiveList() {
    return request(method: RPCMethods.downloadArchiveList);
  }

  Future<Map<String, dynamic>> requestDownloadArchiveStart({
    required Map<String, dynamic> archive,
    bool resume = false,
    bool reParse = false,
  }) {
    return request(
      method: RPCMethods.downloadArchiveStart,
      params: <String, dynamic>{
        'archive': archive,
        'resume': resume,
        'reParse': reParse,
      },
    );
  }

  Future<Map<String, dynamic>> requestDownloadArchivePause({required int gid}) {
    return request(
      method: RPCMethods.downloadArchivePause,
      params: <String, dynamic>{
        'gid': gid,
      },
    );
  }

  Future<Map<String, dynamic>> requestDownloadArchiveResume({required int gid}) {
    return request(
      method: RPCMethods.downloadArchiveResume,
      params: <String, dynamic>{
        'gid': gid,
      },
    );
  }

  Future<Map<String, dynamic>> requestDownloadArchiveDelete({required int gid}) {
    return request(
      method: RPCMethods.downloadArchiveDelete,
      params: <String, dynamic>{
        'gid': gid,
      },
    );
  }

  Future<Map<String, dynamic>> requestDownloadArchivePauseAll() {
    return request(method: RPCMethods.downloadArchivePauseAll);
  }

  Future<Map<String, dynamic>> requestDownloadArchiveResumeAll() {
    return request(method: RPCMethods.downloadArchiveResumeAll);
  }

  Future<Map<String, dynamic>> requestDownloadArchiveCancelTask({required int gid}) {
    return request(
      method: RPCMethods.downloadArchiveCancelTask,
      params: <String, dynamic>{
        'gid': gid,
      },
    );
  }

  Future<Map<String, dynamic>> requestDownloadArchiveUpdateGroup({
    required int gid,
    required String group,
  }) {
    return request(
      method: RPCMethods.downloadArchiveUpdateGroup,
      params: <String, dynamic>{
        'gid': gid,
        'group': group,
      },
    );
  }

  Future<Map<String, dynamic>> requestDownloadArchiveRenameGroup({
    required String oldGroup,
    required String newGroup,
  }) {
    return request(
      method: RPCMethods.downloadArchiveRenameGroup,
      params: <String, dynamic>{
        'oldGroup': oldGroup,
        'newGroup': newGroup,
      },
    );
  }

  Future<Map<String, dynamic>> requestDownloadArchiveDeleteGroup({
    required String group,
  }) {
    return request(
      method: RPCMethods.downloadArchiveDeleteGroup,
      params: <String, dynamic>{
        'group': group,
      },
    );
  }

  Future<Map<String, dynamic>> requestDownloadArchiveChangeParseSource({
    required int gid,
    required int parseSource,
  }) {
    return request(
      method: RPCMethods.downloadArchiveChangeParseSource,
      params: <String, dynamic>{
        'gid': gid,
        'parseSource': parseSource,
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

  String buildDownloadedGalleryImageUrl({
    required int gid,
    required int index,
    String? imagePath,
  }) {
    String address = rpcSetting.serverAddress.value;

    while (address.endsWith('/')) {
      address = address.substring(0, address.length - 1);
    }

    return Uri.parse('$address${RPCConsts.rpcDownloadedGalleryImageEndpoint}')
        .replace(queryParameters: <String, String>{
      'gid': gid.toString(),
      'index': index.toString(),
      if (imagePath != null && imagePath.isNotEmpty) 'path': imagePath,
    }).toString();
  }

  String buildDownloadedGalleryThumbnailUrl({
    required int gid,
    required int index,
  }) {
    String address = rpcSetting.serverAddress.value;

    while (address.endsWith('/')) {
      address = address.substring(0, address.length - 1);
    }

    return Uri.parse('$address${RPCConsts.rpcDownloadedGalleryThumbnailEndpoint}')
        .replace(queryParameters: <String, String>{
      'gid': gid.toString(),
      'index': index.toString(),
    }).toString();
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
