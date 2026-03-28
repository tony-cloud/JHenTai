import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:jhentai/consts/eh_consts.dart';
import 'package:jhentai/consts/rpc_consts.dart';
import 'package:jhentai/database/dao/gallery_history_dao.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/model/gallery_image.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/path_service.dart';
import 'package:jhentai/setting/download_setting.dart';
import 'package:path/path.dart' as path;

const String rpcBridgeServerName = 'JHenTai RPC Bridge';
const String rpcBridgeServerVersion = '0.1.0';

class RpcBridgeServer {
  RpcBridgeServer({
    required this.host,
    required this.port,
    required this.authToken,
    required this.cookieHeader,
    required this.certificatePath,
    required this.privateKeyPath,
    required this.privateKeyPassword,
  });

  final String host;
  final int port;
  final String authToken;
  final String certificatePath;
  final String privateKeyPath;
  final String privateKeyPassword;

  String cookieHeader;

  late final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      headers: {
        HttpHeaders.userAgentHeader: 'JHenTai-RPC-Bridge/$rpcBridgeServerVersion',
      },
    ),
  );

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;

  bool get isRunning => _server != null;

  bool get tlsEnabled => certificatePath.trim().isNotEmpty && privateKeyPath.trim().isNotEmpty;

  List<String> get capabilities => <String>[
        RPCCapabilities.gallerySearch,
        RPCCapabilities.galleryDetail,
        RPCCapabilities.galleryImage,
        RPCCapabilities.forumRead,
        RPCCapabilities.settingRead,
        RPCCapabilities.favoriteRead,
        RPCCapabilities.favoriteWrite,
        RPCCapabilities.commentWrite,
        RPCCapabilities.ratingWrite,
        RPCCapabilities.tagRead,
        RPCCapabilities.tagWrite,
        RPCCapabilities.lookupWrite,
        RPCCapabilities.torrentRead,
        RPCCapabilities.archiveWrite,
        RPCCapabilities.downloadGalleryList,
        RPCCapabilities.downloadGalleryRead,
        RPCCapabilities.downloadGalleryControl,
        RPCCapabilities.downloadGalleryThumbnail,
        RPCCapabilities.historyRead,
        RPCCapabilities.historyWrite,
        RPCCapabilities.newsEvent,
        RPCCapabilities.externalForward,
        RPCCapabilities.authLogin,
        'system.reloadCertificates',
        RPCMethods.authLogin,
        RPCMethods.authSetCookie,
      ];

  Future<void> start() async {
    if (isRunning) {
      return;
    }

    await _bindServer();
    _attachServerListener();
  }

  Future<void> stop() async {
    final HttpServer? oldServer = _server;
    _server = null;

    await _subscription?.cancel();
    _subscription = null;

    await oldServer?.close(force: true);
  }

  Future<Map<String, dynamic>> handleSetCookie(Map<String, dynamic> params) async {
    final String cookie = _requireString(params, <String>['cookie']);
    cookieHeader = cookie;

    return <String, dynamic>{
      'status': 'ok',
      'cookieConfigured': cookieHeader.isNotEmpty,
    };
  }

  Future<void> _bindServer() async {
    final InternetAddress bindAddress =
        host == '0.0.0.0' ? InternetAddress.anyIPv4 : InternetAddress(host);

    if (tlsEnabled) {
      final SecurityContext context = SecurityContext();
      context.useCertificateChain(certificatePath);
      context.usePrivateKey(
        privateKeyPath,
        password: privateKeyPassword.isEmpty ? null : privateKeyPassword,
      );

      _server = await HttpServer.bindSecure(bindAddress, port, context, shared: true);
      return;
    }

    _server = await HttpServer.bind(bindAddress, port, shared: true);
  }

  void _attachServerListener() {
    final HttpServer? currentServer = _server;
    if (currentServer == null) {
      return;
    }

    _subscription = currentServer.listen(
      (HttpRequest request) {
        unawaited(_handleRequest(request));
      },
      onError: (Object error, StackTrace stackTrace) {
        stderr.writeln('[RPC] server stream error: $error');
        stderr.writeln(stackTrace);
      },
      cancelOnError: false,
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    _applyCorsHeaders(request.response);

    if (request.method == 'GET' && request.uri.path == RPCConsts.rpcMediaEndpoint) {
      if (!_isAuthorized(request)) {
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..write('Unauthorized');
        await request.response.close();
        return;
      }

      await _handleMediaProxy(request);
      return;
    }

    if (request.method == 'GET' &&
        request.uri.path == RPCConsts.rpcDownloadedGalleryImageEndpoint) {
      if (!_isAuthorized(request)) {
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..write('Unauthorized');
        await request.response.close();
        return;
      }

      await _handleDownloadedGalleryImage(request);
      return;
    }

    if (request.method == 'GET' &&
        request.uri.path == RPCConsts.rpcDownloadedGalleryThumbnailEndpoint) {
      if (!_isAuthorized(request)) {
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..write('Unauthorized');
        await request.response.close();
        return;
      }

      await _handleDownloadedGalleryThumbnail(request);
      return;
    }

    if (request.method == 'OPTIONS' &&
        (request.uri.path == RPCConsts.rpcEndpoint ||
            request.uri.path == RPCConsts.rpcMediaEndpoint ||
            request.uri.path == RPCConsts.rpcDownloadedGalleryImageEndpoint ||
            request.uri.path == RPCConsts.rpcDownloadedGalleryThumbnailEndpoint)) {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }

    if (request.method != 'POST' || request.uri.path != RPCConsts.rpcEndpoint) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not Found');
      await request.response.close();
      return;
    }

    if (!_isAuthorized(request)) {
      request.response
        ..statusCode = HttpStatus.unauthorized
        ..write('Unauthorized');
      await request.response.close();
      return;
    }

    dynamic id;
    try {
      final String raw = await utf8.decoder.bind(request).join();
      final dynamic decoded = jsonDecode(raw);

      if (decoded is! Map<String, dynamic>) {
        await _writeRpcError(
          request.response,
          id: null,
          code: -32600,
          message: 'Invalid Request',
        );
        return;
      }

      id = decoded['id'];
      final String? method = decoded['method']?.toString();
      final Map<String, dynamic> params = _asMap(decoded['params']);

      if (method == null || method.isEmpty) {
        await _writeRpcError(
          request.response,
          id: id,
          code: -32600,
          message: 'Missing method',
        );
        return;
      }

      final Map<String, dynamic> result = await _dispatch(method, params);
      await _writeRpcSuccess(request.response, id: id, result: result);
    } on FormatException catch (e) {
      await _writeRpcError(
        request.response,
        id: id,
        code: -32700,
        message: 'Parse error: ${e.message}',
      );
    } on RPCBridgeException catch (e) {
      await _writeRpcError(
        request.response,
        id: id,
        code: e.code,
        message: e.message,
        data: e.data,
      );
    } catch (e, stackTrace) {
      stderr.writeln('[RPC] unexpected error: $e');
      stderr.writeln(stackTrace);
      await _writeRpcError(
        request.response,
        id: id,
        code: -32000,
        message: e.toString(),
      );
    }
  }

  void _applyCorsHeaders(HttpResponse response) {
    response.headers
      ..set(HttpHeaders.accessControlAllowOriginHeader, '*')
      ..set(HttpHeaders.accessControlAllowMethodsHeader, 'GET, POST, OPTIONS')
      ..set(
        HttpHeaders.accessControlAllowHeadersHeader,
        'Content-Type, Authorization',
      )
      ..set(HttpHeaders.accessControlMaxAgeHeader, '86400');
  }

  bool _isAuthorized(HttpRequest request) {
    if (authToken.isEmpty) {
      return true;
    }

    final String authHeader = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    return authHeader == 'Bearer $authToken';
  }

  Future<Map<String, dynamic>> _dispatch(
    String method,
    Map<String, dynamic> params,
  ) async {
    switch (method) {
      case RPCMethods.systemHealth:
        return <String, dynamic>{
          'status': 'ok',
          'name': rpcBridgeServerName,
          'version': rpcBridgeServerVersion,
          'tlsEnabled': tlsEnabled,
          'capabilities': capabilities,
        };
      case RPCMethods.systemCapabilities:
        return <String, dynamic>{
          'name': rpcBridgeServerName,
          'version': rpcBridgeServerVersion,
          'capabilities': capabilities,
        };
      case RPCMethods.systemFetchUrl:
        return _handleSystemFetchUrl(params);
      case RPCMethods.newsEvent:
        return _proxyGet(EHConsts.ENews);
      case RPCMethods.galleryPage:
        return _handleGalleryPage(params);
      case RPCMethods.galleryDetail:
        return _handleGalleryDetail(params);
      case RPCMethods.galleryMetadata:
        return _handleGalleryMetadata(params);
      case RPCMethods.galleryMetadatas:
        return _handleGalleryMetadatas(params);
      case RPCMethods.galleryImagePage:
        return _handleGalleryImagePage(params);
      case RPCMethods.forumUser:
        return _handleForumUser(params);
      case RPCMethods.settingPage:
        return _proxyGet(EHConsts.EUconfig);
      case RPCMethods.favoritePopup:
        return _handleFavoritePopup(params);
      case RPCMethods.favoritePage:
        return _proxyGet(EHConsts.EFavorite);
      case RPCMethods.favoriteSort:
        return _handleFavoriteSort(params);
      case RPCMethods.favoriteAdd:
        return _handleFavoriteAdd(params);
      case RPCMethods.favoriteRemove:
        return _handleFavoriteRemove(params);
      case RPCMethods.torrentPage:
        return _handleTorrentPage(params);
      case RPCMethods.myTagsPage:
        return _handleMyTagsPage(params);
      case RPCMethods.myTagsAdd:
        return _handleMyTagsAdd(params);
      case RPCMethods.myTagsDelete:
        return _handleMyTagsDelete(params);
      case RPCMethods.myTagsUpdateSet:
        return _handleMyTagsUpdateSet(params);
      case RPCMethods.commentVote:
        return _handleCommentVote(params);
      case RPCMethods.commentSend:
        return _handleCommentSend(params);
      case RPCMethods.commentUpdate:
        return _handleCommentUpdate(params);
      case RPCMethods.ratingSubmit:
        return _handleRatingSubmit(params);
      case RPCMethods.tagSuggestion:
        return _handleTagSuggestion(params);
      case RPCMethods.lookupImage:
        throw RPCBridgeException(
          code: -32603,
          message: 'lookup.image is not supported by this backend yet',
        );
      case RPCMethods.archiveUnlock:
        return _handleArchiveUnlock(params);
      case RPCMethods.archiveCancel:
        return _handleArchiveCancel(params);
      case RPCMethods.archiveHathDownload:
        return _handleArchiveHathDownload(params);
      case RPCMethods.downloadGalleryList:
        return _handleDownloadGalleryList();
      case RPCMethods.downloadGalleryImages:
        return _handleDownloadGalleryImages(params);
      case RPCMethods.historyPage:
        return _handleHistoryPage(params);
      case RPCMethods.historyRecord:
        return _handleHistoryRecord(params);
      case RPCMethods.historyDelete:
        return _handleHistoryDelete(params);
      case RPCMethods.historyDeleteAll:
        return _handleHistoryDeleteAll();
      case 'system.reloadCertificates':
        return _handleReloadCertificates();
      case RPCMethods.authLogin:
        return _handleAuthLogin(params);
      case RPCMethods.authSetCookie:
        return handleSetCookie(params);
      case RPCMethods.downloadGalleryStart:
        return _handleDownloadGalleryStart(params);
      case RPCMethods.downloadGalleryPause:
        return _handleDownloadGalleryPause(params);
      case RPCMethods.downloadGalleryResume:
        return _handleDownloadGalleryResume(params);
      case RPCMethods.downloadGalleryDelete:
        return _handleDownloadGalleryDelete(params);
      case RPCMethods.downloadGalleryAssignPriority:
        return _handleDownloadGalleryAssignPriority(params);
      case RPCMethods.downloadGalleryPauseAll:
        return _handleDownloadGalleryPauseAll();
      case RPCMethods.downloadGalleryResumeAll:
        return _handleDownloadGalleryResumeAll();
      default:
        throw RPCBridgeException(
          code: -32601,
          message: 'Method not found: $method',
        );
    }
  }

  Future<Map<String, dynamic>> _handleGalleryPage(Map<String, dynamic> params) {
    final String path = _requireString(
      params,
      <String>['url', 'searchPath'],
      fallback: EHConsts.EHome,
    );

    final Map<String, dynamic> query = <String, dynamic>{
      ..._asMap(params['searchQuery']),
      if (params['prevGid'] != null) 'prev': params['prevGid'],
      if (params['nextGid'] != null) 'next': params['nextGid'],
      if (params['seek'] != null) 'seek': params['seek'],
    };

    return _proxyGet(_normalizeUrl(path), queryParameters: query);
  }

  Future<Map<String, dynamic>> _handleGalleryDetail(Map<String, dynamic> params) {
    final String galleryUrl = _requireString(params, <String>['galleryUrl']);
    final int thumbnailsPageIndex = _asInt(params['thumbnailsPageIndex'], fallback: 0);
    final bool showAllComments = _asBool(params['showAllComments']);

    return _proxyGet(
      _normalizeUrl(galleryUrl),
      queryParameters: <String, dynamic>{
        'p': thumbnailsPageIndex,
        'hc': showAllComments ? 1 : 0,
      },
    );
  }

  Future<Map<String, dynamic>> _handleGalleryMetadata(Map<String, dynamic> params) {
    final int gid = _asInt(params['gid']);
    final String token = _requireString(params, <String>['token']);

    return _proxyPost(
      EHConsts.EHApi,
      data: <String, dynamic>{
        'method': 'gdata',
        'gidlist': <List<dynamic>>[
          <dynamic>[gid, token]
        ],
        'namespace': 1,
      },
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: Headers.jsonContentType,
      },
    );
  }

  Future<Map<String, dynamic>> _handleGalleryMetadatas(
    Map<String, dynamic> params,
  ) {
    final dynamic rawList = params['list'];
    if (rawList is! List) {
      throw RPCBridgeException(code: -32602, message: 'list must be an array');
    }

    final List<List<dynamic>> gidList = rawList.map((dynamic item) {
      final Map<String, dynamic> row = _asMap(item);
      return <dynamic>[
        _asInt(row['gid']),
        _requireString(row, <String>['token'])
      ];
    }).toList();

    return _proxyPost(
      EHConsts.EHApi,
      data: <String, dynamic>{
        'method': 'gdata',
        'gidlist': gidList,
        'namespace': 1,
      },
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: Headers.jsonContentType,
      },
    );
  }

  Future<Map<String, dynamic>> _handleGalleryImagePage(
    Map<String, dynamic> params,
  ) {
    final String href = _requireString(params, <String>['href']);

    final Map<String, dynamic> query = <String, dynamic>{};
    if (params['reloadKey'] != null) {
      query['nl'] = params['reloadKey'];
    }

    return _proxyGet(_normalizeUrl(href), queryParameters: query);
  }

  Future<Map<String, dynamic>> _handleSystemFetchUrl(
    Map<String, dynamic> params,
  ) {
    final String url = _requireString(params, <String>['url']);
    final String method = _requireString(
      params,
      <String>['method'],
      fallback: 'GET',
    ).toUpperCase();
    final Map<String, dynamic> queryParameters = _asMap(params['queryParameters']);
    final Map<String, dynamic> rawHeaders = _asMap(params['headers']);
    final bool expectBinary = _asBool(params['expectBinary']);

    return _proxyRequest(
      method: method,
      url: _normalizeUrl(url),
      queryParameters: queryParameters.isEmpty ? null : queryParameters,
      data: params['data'],
      headers: rawHeaders.map((key, value) => MapEntry(key, value.toString())),
      responseType: expectBinary ? ResponseType.bytes : ResponseType.plain,
    );
  }

  Future<Map<String, dynamic>> _handleForumUser(Map<String, dynamic> params) {
    final int ipbMemberId = _asInt(params['ipbMemberId']);

    return _proxyGet(
      EHConsts.EForums,
      queryParameters: <String, dynamic>{
        'showuser': ipbMemberId,
      },
    );
  }

  Future<Map<String, dynamic>> _handleFavoritePopup(
    Map<String, dynamic> params,
  ) {
    final int gid = _asInt(params['gid']);
    final String token = _requireString(params, <String>['token']);
    final String act = _requireString(params, <String>['act']);

    return _proxyGet(
      EHConsts.EPopup,
      queryParameters: <String, dynamic>{
        'gid': gid,
        't': token,
        'act': act,
      },
    );
  }

  Future<Map<String, dynamic>> _handleFavoriteSort(
    Map<String, dynamic> params,
  ) {
    final String inlineSet = _requireString(params, <String>['inlineSet']);

    return _proxyGet(
      EHConsts.EFavorite,
      queryParameters: <String, dynamic>{
        'inline_set': inlineSet,
      },
    );
  }

  Future<Map<String, dynamic>> _handleFavoriteAdd(
    Map<String, dynamic> params,
  ) {
    final int gid = _asInt(params['gid']);
    final String token = _requireString(params, <String>['token']);
    final int favcat = _asInt(params['favcat']);
    final String note = _requireString(params, <String>['note'], fallback: '');

    return _proxyPost(
      EHConsts.EPopup,
      queryParameters: <String, dynamic>{
        'gid': gid,
        't': token,
        'act': 'addfav',
      },
      data: <String, dynamic>{
        'favcat': favcat,
        'favnote': note,
        'apply': 'Add to Favorites',
        'update': 1,
      },
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: Headers.formUrlEncodedContentType,
      },
    );
  }

  Future<Map<String, dynamic>> _handleFavoriteRemove(
    Map<String, dynamic> params,
  ) {
    final int gid = _asInt(params['gid']);
    final String token = _requireString(params, <String>['token']);

    return _proxyPost(
      EHConsts.EPopup,
      queryParameters: <String, dynamic>{
        'gid': gid,
        't': token,
        'act': 'addfav',
      },
      data: <String, dynamic>{
        'favcat': 'favdel',
        'favnote': '',
        'apply': 'Apply Changes',
        'update': 1,
      },
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: Headers.formUrlEncodedContentType,
      },
    );
  }

  Future<Map<String, dynamic>> _handleTorrentPage(Map<String, dynamic> params) {
    final int gid = _asInt(params['gid']);
    final String token = _requireString(params, <String>['token']);

    return _proxyGet(
      EHConsts.ETorrent,
      queryParameters: <String, dynamic>{
        'gid': gid,
        't': token,
      },
    );
  }

  Future<Map<String, dynamic>> _handleMyTagsPage(Map<String, dynamic> params) {
    final int tagSetNo = _asInt(params['tagSetNo'], fallback: 1);

    return _proxyGet(
      EHConsts.EMyTags,
      queryParameters: <String, dynamic>{
        'tagset': tagSetNo,
      },
    );
  }

  Future<Map<String, dynamic>> _handleMyTagsAdd(Map<String, dynamic> params) {
    final String tag = _requireString(params, <String>['tag']);
    final String tagColor = _requireString(params, <String>['tagColor'], fallback: '');
    final int tagWeight = _asInt(params['tagWeight'], fallback: 10);
    final bool watch = _asBool(params['watch']);
    final bool hidden = _asBool(params['hidden']);
    final int tagSetNo = _asInt(params['tagSetNo'], fallback: 1);

    final Map<String, dynamic> data = <String, dynamic>{
      'usertag_action': 'add',
      'tagname_new': tag,
      'tagcolor_new': tagColor,
      'usertag_target': 0,
      'tagweight_new': tagWeight,
      if (hidden) 'taghide_new': 'on',
      if (watch) 'tagwatch_new': 'on',
    };

    return _proxyPost(
      EHConsts.EMyTags,
      queryParameters: <String, dynamic>{
        'tagset': tagSetNo,
      },
      data: data,
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: Headers.formUrlEncodedContentType,
      },
    );
  }

  Future<Map<String, dynamic>> _handleMyTagsDelete(Map<String, dynamic> params) {
    final int watchedTagId = _asInt(params['watchedTagId']);
    final int tagSetNo = _asInt(params['tagSetNo'], fallback: 1);

    return _proxyPost(
      EHConsts.EMyTags,
      queryParameters: <String, dynamic>{
        'tagset': tagSetNo,
      },
      data: <String, dynamic>{
        'usertag_action': 'mass',
        'tagname_new': '',
        'tagcolor_new': '',
        'usertag_target': 0,
        'tagweight_new': 10,
        'modify_usertags[]': watchedTagId,
      },
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: Headers.formUrlEncodedContentType,
      },
    );
  }

  Future<Map<String, dynamic>> _handleMyTagsUpdateSet(
    Map<String, dynamic> params,
  ) {
    final int tagSetNo = _asInt(params['tagSetNo'], fallback: 1);
    final bool enable = _asBool(params['enable']);
    final String color = _requireString(params, <String>['color'], fallback: '');

    return _proxyPost(
      EHConsts.EMyTags,
      queryParameters: <String, dynamic>{
        'tagset': tagSetNo,
      },
      data: <String, dynamic>{
        'tagset_action': 'update',
        'tagset_name': '',
        if (enable) 'tagset_enable': 'on',
        'tagset_color': color,
      },
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: Headers.formUrlEncodedContentType,
      },
    );
  }

  Future<Map<String, dynamic>> _handleCommentVote(Map<String, dynamic> params) {
    final int gid = _asInt(params['gid']);
    final String token = _requireString(params, <String>['token']);
    final int apiuid = _asInt(params['apiuid']);
    final String apikey = _requireString(params, <String>['apikey']);
    final int commentId = _asInt(params['commentId']);
    final bool isVotingUp = _asBool(params['isVotingUp']);

    return _proxyPost(
      EHConsts.EApi,
      data: <String, dynamic>{
        'apikey': apikey,
        'apiuid': apiuid,
        'gid': gid,
        'method': 'votecomment',
        'token': token,
        'comment_vote': isVotingUp ? 1 : -1,
        'comment_id': commentId,
      },
    );
  }

  Future<Map<String, dynamic>> _handleCommentSend(Map<String, dynamic> params) {
    final String galleryUrl = _requireString(params, <String>['galleryUrl']);
    final String content = _requireString(params, <String>['content']);

    return _proxyPost(
      _normalizeUrl(galleryUrl),
      data: <String, dynamic>{
        'commenttext_new': content,
      },
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: Headers.formUrlEncodedContentType,
      },
    );
  }

  Future<Map<String, dynamic>> _handleCommentUpdate(Map<String, dynamic> params) {
    final String galleryUrl = _requireString(params, <String>['galleryUrl']);
    final String content = _requireString(params, <String>['content']);
    final int commentId = _asInt(params['commentId']);

    return _proxyPost(
      _normalizeUrl(galleryUrl),
      data: <String, dynamic>{
        'edit_comment': commentId,
        'commenttext_edit': content,
      },
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: Headers.formUrlEncodedContentType,
      },
    );
  }

  Future<Map<String, dynamic>> _handleRatingSubmit(Map<String, dynamic> params) {
    final int gid = _asInt(params['gid']);
    final String token = _requireString(params, <String>['token']);
    final int apiuid = _asInt(params['apiuid']);
    final String apikey = _requireString(params, <String>['apikey']);
    final int rating = _asInt(params['rating']);

    return _proxyPost(
      EHConsts.EApi,
      data: <String, dynamic>{
        'apikey': apikey,
        'apiuid': apiuid,
        'gid': gid,
        'method': 'rategallery',
        'rating': rating,
        'token': token,
      },
    );
  }

  Future<Map<String, dynamic>> _handleTagSuggestion(Map<String, dynamic> params) {
    final String keyword = _requireString(params, <String>['keyword']);

    return _proxyPost(
      EHConsts.EApi,
      data: <String, dynamic>{
        'method': 'tagsuggest',
        'text': keyword,
      },
    );
  }

  Future<Map<String, dynamic>> _handleArchiveUnlock(Map<String, dynamic> params) {
    final String url = _requireString(params, <String>['url']);
    final bool isOriginal = _asBool(params['isOriginal']);

    return _proxyPost(
      _normalizeUrl(url),
      data: FormData.fromMap(<String, dynamic>{
        'dltype': isOriginal ? 'org' : 'res',
        'dlcheck': isOriginal ? 'Download Original Archive' : 'Download Resample Archive',
      }),
    );
  }

  Future<Map<String, dynamic>> _handleArchiveCancel(Map<String, dynamic> params) {
    final String url = _requireString(params, <String>['url']);

    return _proxyPost(
      _normalizeUrl(url),
      data: FormData.fromMap(<String, dynamic>{
        'invalidate_sessions': 1,
      }),
    );
  }

  Future<Map<String, dynamic>> _handleArchiveHathDownload(
    Map<String, dynamic> params,
  ) {
    final String url = _requireString(params, <String>['url']);
    final String resolution = _requireString(params, <String>['resolution']);

    return _proxyPost(
      _normalizeUrl(url),
      data: FormData.fromMap(<String, dynamic>{
        'hathdl_xres': resolution,
      }),
    );
  }

  Future<Map<String, dynamic>> _handleDownloadGalleryList() async {
    final List<Map<String, dynamic>> infos = galleryDownloadService.gallerys.map((gallery) {
      final GalleryDownloadInfo? info = galleryDownloadService.galleryDownloadInfos[gallery.gid];
      final GalleryImage? coverImage = _resolveCoverImage(gid: gallery.gid, info: info);
      final GalleryDownloadProgress progress = _resolveDownloadProgress(
        gid: gallery.gid,
        info: info,
        pageCount: gallery.pageCount,
      );

      return <String, dynamic>{
        'gid': gallery.gid,
        'group': info?.group ?? gallery.groupName,
        'priority': info?.priority ?? gallery.priority,
        'sortOrder': info?.sortOrder ?? gallery.sortOrder,
        'downloadProgress': progress.toJson(),
        'coverImage': coverImage?.toJson(),
        'speed': info?.speedComputer.speed ?? '0 B/s',
      };
    }).toList(growable: false);

    return <String, dynamic>{
      'groups': List<String>.from(galleryDownloadService.allGroups),
      'galleries': galleryDownloadService.gallerys
          .map((gallery) => gallery.toJson())
          .toList(growable: false),
      'infos': infos,
    };
  }

  Future<Map<String, dynamic>> _handleDownloadGalleryImages(
    Map<String, dynamic> params,
  ) async {
    final int gid = _asInt(params['gid']);
    final GalleryDownloadInfo? info = galleryDownloadService.galleryDownloadInfos[gid];
    GalleryDownloadedData? gallery;
    for (final GalleryDownloadedData item in galleryDownloadService.gallerys) {
      if (item.gid == gid) {
        gallery = item;
        break;
      }
    }

    if (info == null && gallery == null) {
      throw RPCBridgeException(
        code: -32040,
        message: 'Downloaded gallery not found: $gid',
      );
    }

    final int pageCount = gallery?.pageCount ?? info!.images.length;
    final List<Map<String, dynamic>?> images =
        List<Map<String, dynamic>?>.generate(pageCount, (index) {
      final GalleryImage? memoryImage =
          (info != null && index < info.images.length) ? info.images[index] : null;
      final GalleryImage? image = memoryImage ?? _resolveImageFromDisk(gid: gid, index: index);
      return image?.toJson();
    }, growable: false);

    final GalleryDownloadProgress progress = _resolveDownloadProgress(
      gid: gid,
      info: info,
      pageCount: pageCount,
      resolvedImages: images,
    );

    return <String, dynamic>{
      'gid': gid,
      'downloadProgress': progress.toJson(),
      'images': images,
    };
  }

  GalleryImage? _resolveCoverImage({
    required int gid,
    required GalleryDownloadInfo? info,
  }) {
    if (info != null) {
      for (final GalleryImage? image in info.images) {
        if (image != null) {
          return image;
        }
      }
    }

    return _resolveImageFromDisk(gid: gid, index: 0);
  }

  GalleryDownloadProgress _resolveDownloadProgress({
    required int gid,
    required GalleryDownloadInfo? info,
    required int pageCount,
    List<Map<String, dynamic>?>? resolvedImages,
  }) {
    if (info != null) {
      return info.downloadProgress;
    }

    final List<bool> hasDownloaded = List<bool>.generate(pageCount, (index) {
      if (resolvedImages != null) {
        return resolvedImages[index] != null;
      }

      return _resolveImageFromDisk(gid: gid, index: index) != null;
    }, growable: false);

    final int curCount = hasDownloaded.where((value) => value).length;
    final DownloadStatus status = curCount == pageCount
        ? DownloadStatus.downloaded
        : (curCount == 0 ? DownloadStatus.paused : DownloadStatus.downloading);

    return GalleryDownloadProgress(
      curCount: curCount,
      totalCount: pageCount,
      downloadStatus: status,
      hasDownloaded: hasDownloaded,
    );
  }

  GalleryImage? _resolveImageFromDisk({required int gid, required int index}) {
    final File? file = _resolveByGidAndIndex(gid: gid, index: index);
    if (file == null || !file.existsSync()) {
      return null;
    }

    final String relativePath = path.relative(
      file.absolute.path,
      from: pathService.getVisibleDir().path,
    );

    return GalleryImage(
      url: '',
      path: relativePath,
      downloadStatus: DownloadStatus.downloaded,
    );
  }

  Future<Map<String, dynamic>> _handleHistoryPage(Map<String, dynamic> params) async {
    final int pageIndex = _asInt(params['pageIndex'], fallback: 0);
    final int pageSize = _asInt(params['pageSize'], fallback: 100);

    if (pageIndex < 0 || pageSize <= 0) {
      throw RPCBridgeException(
        code: -32602,
        message: 'Invalid pageIndex/pageSize',
      );
    }

    final List<GalleryHistoryV2Data> histories =
        await GalleryHistoryDao.selectByPageIndex(pageIndex, pageSize);
    final int totalCount = await GalleryHistoryDao.selectTotalCount();

    return <String, dynamic>{
      'pageIndex': pageIndex,
      'pageSize': pageSize,
      'totalCount': totalCount,
      'records': histories.map((history) => history.toJson()).toList(growable: false),
    };
  }

  Future<Map<String, dynamic>> _handleHistoryRecord(Map<String, dynamic> params) async {
    final int gid = _asInt(params['gid']);
    final String jsonBody = _requireString(params, <String>['jsonBody']);
    final String lastReadTime = _requireString(
      params,
      <String>['lastReadTime'],
      fallback: DateTime.now().toString(),
    );

    await GalleryHistoryDao.replaceHistory(
      GalleryHistoryV2Data(
        gid: gid,
        jsonBody: jsonBody,
        lastReadTime: lastReadTime,
      ),
    );

    return <String, dynamic>{
      'status': 'ok',
      'gid': gid,
    };
  }

  Future<Map<String, dynamic>> _handleHistoryDelete(Map<String, dynamic> params) async {
    final int gid = _asInt(params['gid']);
    final int deleted = await GalleryHistoryDao.deleteHistory(gid);

    return <String, dynamic>{
      'status': 'ok',
      'gid': gid,
      'deleted': deleted > 0,
    };
  }

  Future<Map<String, dynamic>> _handleHistoryDeleteAll() async {
    final int deletedCount = await GalleryHistoryDao.deleteAllHistory();

    return <String, dynamic>{
      'status': 'ok',
      'deletedCount': deletedCount,
    };
  }

  Future<Map<String, dynamic>> _handleAuthLogin(Map<String, dynamic> params) async {
    final String userName = _requireString(params, <String>['userName']);
    final String passWord = _requireString(params, <String>['passWord']);

    final Map<String, dynamic> result = await _proxyPost(
      EHConsts.EForums,
      options: Options(contentType: Headers.formUrlEncodedContentType),
      queryParameters: <String, dynamic>{'act': 'Login', 'CODE': '01'},
      data: <String, dynamic>{
        'referer': 'https://forums.e-hentai.org/index.php?',
        'b': '',
        'bt': '',
        'UserName': userName,
        'PassWord': passWord,
        'CookieDate': 365,
      },
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: Headers.formUrlEncodedContentType,
      },
    );

    _mergeCookieHeaderFromRpcResult(result);

    return result;
  }

  Future<Map<String, dynamic>> _handleDownloadGalleryStart(
    Map<String, dynamic> params,
  ) async {
    final Map<String, dynamic> rawGallery = _asMap(params['gallery']);
    if (rawGallery.isEmpty) {
      throw RPCBridgeException(code: -32602, message: 'gallery must be an object');
    }

    final GalleryDownloadedData gallery = GalleryDownloadedData.fromJson(rawGallery);
    await galleryDownloadService.downloadGallery(gallery);

    return <String, dynamic>{
      'status': 'ok',
      'gid': gallery.gid,
    };
  }

  Future<Map<String, dynamic>> _handleDownloadGalleryPause(
    Map<String, dynamic> params,
  ) async {
    final int gid = _asInt(params['gid']);
    await galleryDownloadService.pauseDownloadGalleryByGid(gid);

    return <String, dynamic>{
      'status': 'ok',
      'gid': gid,
    };
  }

  Future<Map<String, dynamic>> _handleDownloadGalleryResume(
    Map<String, dynamic> params,
  ) async {
    final int gid = _asInt(params['gid']);
    await galleryDownloadService.resumeDownloadGalleryByGid(gid);

    return <String, dynamic>{
      'status': 'ok',
      'gid': gid,
    };
  }

  Future<Map<String, dynamic>> _handleDownloadGalleryDelete(
    Map<String, dynamic> params,
  ) async {
    final int gid = _asInt(params['gid']);
    final bool deleteImages =
        params.containsKey('deleteImages') ? _asBool(params['deleteImages']) : true;

    GalleryDownloadedData? gallery;
    for (final GalleryDownloadedData item in galleryDownloadService.gallerys) {
      if (item.gid == gid) {
        gallery = item;
        break;
      }
    }
    if (gallery == null) {
      throw RPCBridgeException(
        code: -32040,
        message: 'Downloaded gallery not found: $gid',
      );
    }

    await galleryDownloadService.deleteGallery(gallery, deleteImages: deleteImages);

    return <String, dynamic>{
      'status': 'ok',
      'gid': gid,
      'deleteImages': deleteImages,
    };
  }

  Future<Map<String, dynamic>> _handleDownloadGalleryAssignPriority(
    Map<String, dynamic> params,
  ) async {
    final int gid = _asInt(params['gid']);
    final int priority = _asInt(params['priority']);

    GalleryDownloadedData? gallery;
    for (final GalleryDownloadedData item in galleryDownloadService.gallerys) {
      if (item.gid == gid) {
        gallery = item;
        break;
      }
    }
    if (gallery == null) {
      throw RPCBridgeException(
        code: -32040,
        message: 'Downloaded gallery not found: $gid',
      );
    }

    await galleryDownloadService.assignPriority(gallery, priority);

    return <String, dynamic>{
      'status': 'ok',
      'gid': gid,
      'priority': priority,
    };
  }

  Future<Map<String, dynamic>> _handleDownloadGalleryPauseAll() async {
    await galleryDownloadService.pauseAllDownloadGallery();

    return <String, dynamic>{
      'status': 'ok',
    };
  }

  Future<Map<String, dynamic>> _handleDownloadGalleryResumeAll() async {
    await galleryDownloadService.resumeAllDownloadGallery();

    return <String, dynamic>{
      'status': 'ok',
    };
  }

  Future<Map<String, dynamic>> _handleReloadCertificates() async {
    if (!tlsEnabled) {
      throw RPCBridgeException(
        code: -32010,
        message: 'TLS is disabled. Set certificate and key first.',
      );
    }

    unawaited(_restartSecureServer());
    return <String, dynamic>{
      'status': 'reloading',
      'tlsEnabled': true,
    };
  }

  Future<void> _restartSecureServer() async {
    final HttpServer? oldServer = _server;
    _server = null;

    await _subscription?.cancel();
    _subscription = null;

    await oldServer?.close(force: true);
    await _bindServer();
    _attachServerListener();
  }

  Future<Map<String, dynamic>> _proxyGet(
    String url, {
    Map<String, dynamic>? queryParameters,
  }) {
    return _proxyRequest(
      method: 'GET',
      url: url,
      queryParameters: queryParameters,
    );
  }

  Future<Map<String, dynamic>> _proxyPost(
    String url, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    Map<String, String>? headers,
  }) {
    return _proxyRequest(
      method: 'POST',
      url: url,
      data: data,
      queryParameters: queryParameters,
      options: options,
      headers: headers,
    );
  }

  Future<Map<String, dynamic>> _proxyRequest({
    required String method,
    required String url,
    Map<String, dynamic>? queryParameters,
    dynamic data,
    Options? options,
    Map<String, String>? headers,
    ResponseType responseType = ResponseType.plain,
  }) async {
    try {
      final Response response = await _dio.request(
        url,
        queryParameters: queryParameters,
        data: data,
        options: (options ?? Options()).copyWith(
          method: method,
          validateStatus: (_) => true,
          headers: <String, dynamic>{
            if (cookieHeader.trim().isNotEmpty) HttpHeaders.cookieHeader: cookieHeader,
            ...?options?.headers,
            ...?headers,
          },
          responseType: responseType,
        ),
      );

      return <String, dynamic>{
        'statusCode': response.statusCode,
        'headers': response.headers.map,
        'data': response.data,
      };
    } on DioException catch (e) {
      throw RPCBridgeException(
        code: -32020,
        message: 'Upstream request failed',
        data: <String, dynamic>{
          'statusCode': e.response?.statusCode,
          'type': e.type.toString(),
          'message': e.message,
          'data': e.response?.data,
          'headers': e.response?.headers.map,
        },
      );
    }
  }

  void _mergeCookieHeaderFromRpcResult(Map<String, dynamic> result) {
    final dynamic rawHeaders = result['headers'];
    if (rawHeaders is! Map) {
      return;
    }

    final dynamic rawSetCookie = rawHeaders['set-cookie'] ?? rawHeaders['Set-Cookie'];
    if (rawSetCookie == null) {
      return;
    }

    final List<String> setCookieValues = rawSetCookie is List
        ? rawSetCookie.map((item) => item.toString()).toList(growable: false)
        : <String>[rawSetCookie.toString()];
    if (setCookieValues.isEmpty) {
      return;
    }

    final Map<String, String> merged = <String, String>{};
    for (final String part in cookieHeader.split(';')) {
      final String trimmed = part.trim();
      if (trimmed.isEmpty || !trimmed.contains('=')) {
        continue;
      }
      final int idx = trimmed.indexOf('=');
      merged[trimmed.substring(0, idx)] = trimmed.substring(idx + 1);
    }

    for (final String value in setCookieValues) {
      try {
        final Cookie cookie = Cookie.fromSetCookieValue(value);
        if (cookie.name.isNotEmpty) {
          merged[cookie.name] = cookie.value;
        }
      } catch (_) {
        continue;
      }
    }

    cookieHeader = merged.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');
  }

  Future<void> _handleMediaProxy(HttpRequest request) async {
    final String rawUrl = request.uri.queryParameters['url']?.trim() ?? '';
    if (rawUrl.isEmpty) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Missing url');
      await request.response.close();
      return;
    }

    final String url = _normalizeUrl(rawUrl);

    try {
      final Response<ResponseBody> upstream = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          headers: <String, dynamic>{
            if (cookieHeader.trim().isNotEmpty) HttpHeaders.cookieHeader: cookieHeader,
          },
        ),
      );

      final ResponseBody body = upstream.data!;
      request.response.statusCode = upstream.statusCode ?? HttpStatus.ok;

      final String? contentType = body.headers[HttpHeaders.contentTypeHeader]?.first;
      if (contentType != null && contentType.isNotEmpty) {
        request.response.headers.set(HttpHeaders.contentTypeHeader, contentType);
      }

      final String? cacheControl = body.headers[HttpHeaders.cacheControlHeader]?.first;
      if (cacheControl != null && cacheControl.isNotEmpty) {
        request.response.headers.set(HttpHeaders.cacheControlHeader, cacheControl);
      }

      final String? contentLength = body.headers[HttpHeaders.contentLengthHeader]?.first;
      if (contentLength != null && contentLength.isNotEmpty) {
        request.response.headers.set(HttpHeaders.contentLengthHeader, contentLength);
      }

      await request.response.addStream(body.stream);
      await request.response.close();
    } on DioException catch (e) {
      request.response
        ..statusCode = e.response?.statusCode ?? HttpStatus.badGateway
        ..write('Upstream media request failed');
      await request.response.close();
    }
  }

  Future<void> _handleDownloadedGalleryImage(HttpRequest request) async {
    await _handleDownloadedGalleryAsset(request);
  }

  Future<void> _handleDownloadedGalleryThumbnail(HttpRequest request) async {
    await _handleDownloadedGalleryAsset(request);
  }

  Future<void> _handleDownloadedGalleryAsset(HttpRequest request) async {
    final int gid = _asInt(request.uri.queryParameters['gid']);
    final int index = _asInt(request.uri.queryParameters['index'], fallback: -1);
    final String? relativePath = request.uri.queryParameters['path'];

    final File? file = _resolveDownloadedGalleryFile(
      gid: gid,
      index: index,
      relativePath: relativePath,
    );

    if (file == null || !file.existsSync()) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Downloaded image not found');
      await request.response.close();
      return;
    }

    final ContentType contentType = _guessImageContentType(file.path);
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = contentType
      ..headers.set(HttpHeaders.contentLengthHeader, file.lengthSync().toString());

    await request.response.addStream(file.openRead());
    await request.response.close();
  }

  File? _resolveDownloadedGalleryFile({
    required int gid,
    required int index,
    required String? relativePath,
  }) {
    if (relativePath != null && relativePath.trim().isNotEmpty) {
      final File? file = _resolveByRelativePath(relativePath.trim());
      if (file != null) {
        return file;
      }
    }

    if (gid <= 0 || index < 0) {
      return null;
    }

    final GalleryDownloadInfo? info = galleryDownloadService.galleryDownloadInfos[gid];
    if (info != null && index < info.images.length) {
      final GalleryImage? image = info.images[index];
      final String? imagePath = image?.path;
      if (imagePath != null && imagePath.isNotEmpty) {
        final File? file = _resolveByRelativePath(imagePath);
        if (file != null) {
          return file;
        }
      }
    }

    return _resolveByGidAndIndex(gid: gid, index: index);
  }

  File? _resolveByRelativePath(String relativePath) {
    final String absolutePath =
        GalleryDownloadService.computeImageDownloadAbsolutePathFromRelativePath(
      relativePath,
    );
    final File file = File(absolutePath);

    if (!_isUnderDownloadPath(file.path)) {
      return null;
    }

    return file;
  }

  File? _resolveByGidAndIndex({required int gid, required int index}) {
    final Directory downloadDir = Directory(downloadSetting.downloadPath.value);
    if (!downloadDir.existsSync()) {
      return null;
    }

    final String directoryPrefix = '$gid - ';
    final String filePrefix = '$index.';

    for (final FileSystemEntity entity in downloadDir.listSync()) {
      if (entity is! Directory) {
        continue;
      }

      final String galleryDirName = path.basename(entity.path);
      if (!galleryDirName.startsWith(directoryPrefix)) {
        continue;
      }

      for (final FileSystemEntity child in entity.listSync()) {
        if (child is! File) {
          continue;
        }

        final String fileName = path.basename(child.path);
        if (fileName.startsWith(filePrefix) && _isUnderDownloadPath(child.path)) {
          return child;
        }
      }
    }

    return null;
  }

  bool _isUnderDownloadPath(String targetPath) {
    final String downloadRoot = Directory(downloadSetting.downloadPath.value).absolute.path;
    final String normalizedRoot = path.normalize(downloadRoot);
    final String normalizedTarget = path.normalize(File(targetPath).absolute.path);

    return normalizedTarget == normalizedRoot || path.isWithin(normalizedRoot, normalizedTarget);
  }

  Future<void> _writeRpcSuccess(
    HttpResponse response, {
    required dynamic id,
    required Map<String, dynamic> result,
  }) async {
    response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': result,
        }),
      );

    await response.close();
  }

  Future<void> _writeRpcError(
    HttpResponse response, {
    required dynamic id,
    required int code,
    required String message,
    Map<String, dynamic>? data,
  }) async {
    response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'error': <String, dynamic>{
            'code': code,
            'message': message,
            if (data != null) 'data': data,
          },
        }),
      );

    await response.close();
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }

    if (value is Map) {
      return value.map((dynamic key, dynamic value) {
        return MapEntry(key.toString(), value);
      });
    }

    return <String, dynamic>{};
  }

  static String _requireString(
    Map<String, dynamic> params,
    List<String> keys, {
    String? fallback,
  }) {
    for (final String key in keys) {
      final dynamic value = params[key];
      if (value == null) {
        continue;
      }

      final String str = value.toString().trim();
      if (str.isNotEmpty) {
        return str;
      }
    }

    if (fallback != null) {
      return fallback;
    }

    throw RPCBridgeException(
      code: -32602,
      message: 'Missing required parameter: ${keys.join('/')}',
    );
  }

  static bool _asBool(dynamic value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      final String normalized = value.trim().toLowerCase();
      return normalized == '1' || normalized == 'true' || normalized == 'yes';
    }

    return false;
  }

  static int _asInt(dynamic value, {int fallback = 0}) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value.trim()) ?? fallback;
    }

    return fallback;
  }

  static String _normalizeUrl(String url) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return url;
    }

    return Uri.parse(EHConsts.EHIndex).resolve(url).toString();
  }

  static ContentType _guessImageContentType(String path) {
    final String normalized = path.toLowerCase();
    if (normalized.endsWith('.png')) {
      return ContentType('image', 'png');
    }
    if (normalized.endsWith('.webp')) {
      return ContentType('image', 'webp');
    }
    if (normalized.endsWith('.gif')) {
      return ContentType('image', 'gif');
    }
    if (normalized.endsWith('.bmp')) {
      return ContentType('image', 'bmp');
    }

    return ContentType('image', 'jpeg');
  }
}

class RPCBridgeException implements Exception {
  RPCBridgeException({
    required this.code,
    required this.message,
    this.data,
  });

  final int code;
  final String message;
  final Map<String, dynamic>? data;
}
