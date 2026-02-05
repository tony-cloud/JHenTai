import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:logger/web.dart';

import 'package:jhentai/downloader/src/exception/j_download_exception.dart';
import 'package:jhentai/downloader/src/model/main_isolate_message.dart';
import 'package:jhentai/downloader/src/model/proxy_config.dart';
import 'package:jhentai/downloader/src/model/sub_isolate_message.dart';
import 'package:jhentai/utils/socks_proxy.dart';

class SubIsolateManager {
  final ReceivePort _subReceivePort;
  final SendPort _mainSendPort;

  late final ProxyConfig? _proxyConfig;
  final Dio _dohClient = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );
  final Map<String, _SubDnsCacheEntry> _dnsCache = {};

  bool _enableDoh = false;
  String _dohEndpoint = '';

  static const Duration _defaultTtl = Duration(minutes: 5);

  CancelToken? _cancelToken;

  SubIsolateManager({
    required SendPort mainSendPort,
  })  : _mainSendPort = mainSendPort,
        _subReceivePort = ReceivePort() {
    _mainSendPort.send(SubIsolateMessage(SubIsolateMessageType.created, _subReceivePort.sendPort));

    _subReceivePort.listen((message) {
      _mainSendPort.send(SubIsolateMessage(
          SubIsolateMessageType.log, LogEvent(Level.debug, 'received main message: $message')));

      switch (message.type) {
        case MainIsolateMessageType.init:
          message = message as MainIsolateMessage<
              ({
                ProxyConfig? proxyConfig,
                bool enableDoh,
                String dohEndpoint,
              })>;
          _proxyConfig = message.data.proxyConfig;
          _enableDoh = message.data.enableDoh;
          _dohEndpoint = message.data.dohEndpoint;
          SocksProxy.initProxy(
            findProxy:
                _proxyConfig?.type == ProxyType.socks5 || _proxyConfig?.type == ProxyType.socks4
                    ? (_) => 'DIRECT'
                    : ProxyConfig.toFindProxy(_proxyConfig),
            socksConfig: () => _buildSocksConfig(_proxyConfig),
            lookup: _enableDoh ? _lookupHost : null,
          );
          _configureDohClient();
          _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.inited, null));
          break;
        case MainIsolateMessageType.download:
          message = message as MainIsolateMessage<
              ({
                String url,
                String downloadPath,
                ({int start, int end}) downloadRange,
                int fileWriteOffset
              })>;
          download(
            message.data.url,
            message.data.downloadPath,
            message.data.downloadRange,
            message.data.fileWriteOffset,
          );
          break;
        case MainIsolateMessageType.close:
          if (_cancelToken == null || _cancelToken!.isCancelled) {
            _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.closeReady, null));
          } else {
            _cancelToken!.cancel();
          }
          break;
        default:
          break;
      }
    });
  }

  Future<void> download(String url, String downloadPath, ({int start, int end}) downloadRange,
      int fileWriteOffset) async {
    _cancelToken ??= CancelToken();
    Response<ResponseBody> response;

    _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.begin, null));
    try {
      response = await Dio().get(
        url,
        options: Options(
          sendTimeout: const Duration(seconds: 5),
          preserveHeaderCase: true,
          headers: {'Range': '${downloadRange.start}-${downloadRange.end - 1}'},
          responseType: ResponseType.stream,
        ),
        cancelToken: _cancelToken,
      );
    } on DioException catch (e) {
      _cancelToken = null;

      if (e.type == DioExceptionType.cancel) {
        _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.closeReady, null));
      } else {
        e.response?.data = null;
        e.requestOptions.cancelToken = null;
        _mainSendPort.send(
          SubIsolateMessage<JDownloadException>(
            SubIsolateMessageType.error,
            JDownloadException(
              JDownloadExceptionType.downloadFailed,
              error: e,
            ),
          ),
        );
      }

      return;
    }

    if (response.statusCode != HttpStatus.partialContent) {
      _cancelToken!.cancel();
      _cancelToken = null;

      return _mainSendPort.send(
        SubIsolateMessage<JDownloadException>(
          SubIsolateMessageType.error,
          JDownloadException(JDownloadExceptionType.serverNotSupport),
        ),
      );
    }

    _mainSendPort.send(
        SubIsolateMessage(SubIsolateMessageType.log, LogEvent(Level.debug, 'open download file')));

    File downloadFile = File(downloadPath);
    RandomAccessFile raf = await downloadFile.open(mode: FileMode.writeOnlyAppend);
    await raf.setPosition(fileWriteOffset);

    Future<void>? asyncWrite;
    bool closed = false;
    Future<void> close() async {
      if (!closed) {
        closed = true;
        await asyncWrite;
        await raf.close().catchError((_) => raf);
        _mainSendPort.send(SubIsolateMessage(
            SubIsolateMessageType.log, LogEvent(Level.debug, 'close download file')));
      }
    }

    Stream<Uint8List> stream = response.data!.stream;
    late StreamSubscription subscription;
    subscription = stream.listen(
      (data) {
        subscription.pause();
        asyncWrite = raf.writeFrom(data).then((result) {
          _mainSendPort.send(SubIsolateMessage<int>(SubIsolateMessageType.progress, data.length));
          raf = result;
          if (_cancelToken != null && !_cancelToken!.isCancelled) {
            subscription.resume();
          }
        }).catchError((e) async {
          await subscription.cancel().catchError((_) {});
          closed = true;
          await raf.close().catchError((_) => raf);
          _mainSendPort.send(SubIsolateMessage(
              SubIsolateMessageType.log, LogEvent(Level.debug, 'close download file')));
          _mainSendPort.send(
            SubIsolateMessage<JDownloadException>(
              SubIsolateMessageType.error,
              JDownloadException(JDownloadExceptionType.writeDownloadFileFailed, error: e),
            ),
          );
        });
      },
      onDone: () async {
        await asyncWrite;
        closed = true;
        await raf.close().catchError((_) => raf);
        _mainSendPort.send(SubIsolateMessage(
            SubIsolateMessageType.log, LogEvent(Level.debug, 'close download file')));
        _cancelToken = null;
        _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.done, null));
      },
      onError: (e) async {
        await close();
        _cancelToken = null;
        _mainSendPort.send(SubIsolateMessage(SubIsolateMessageType.error,
            JDownloadException(JDownloadExceptionType.receiveDataFailed, error: e)));
      },
      cancelOnError: true,
    );

    _cancelToken?.whenCancel.then((_) async {
      await subscription.cancel();
      await close();
      _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.closeReady, null));
    });
  }

  void _configureDohClient() {
    final IOHttpClientAdapter adapter = _dohClient.httpClientAdapter as IOHttpClientAdapter;
    adapter.createHttpClient = () {
      final SocksProxyConfiguration? socksConfig = _buildSocksConfig(_proxyConfig);
      final HttpClient client = createProxyHttpClient(
        socksConfig: socksConfig,
      );
      if (socksConfig != null) {
        client.findProxy = (_) => 'DIRECT';
      } else if (_proxyConfig?.type == ProxyType.socks4) {
        client.findProxy = (_) => 'DIRECT';
      } else {
        client.findProxy = ProxyConfig.toFindProxy(_proxyConfig);
      }
      return client;
    };
  }

  Future<List<InternetAddress>> _lookupHost(
    String host, {
    InternetAddressType type = InternetAddressType.any,
  }) async {
    final InternetAddress? ip = InternetAddress.tryParse(host);
    if (ip != null) {
      return [ip];
    }

    if (!_enableDoh || _dohEndpoint.trim().isEmpty) {
      return InternetAddress.lookup(host, type: type);
    }

    final String cacheKey = '$host-${type.name}';
    final _SubDnsCacheEntry? cached = _dnsCache[cacheKey];
    if (cached != null && cached.expireAt.isAfter(DateTime.now())) {
      return cached.addresses;
    }

    try {
      final _SubLookupResult result = await _queryDoh(host, type: type);
      if (result.addresses.isNotEmpty) {
        _dnsCache[cacheKey] = _SubDnsCacheEntry(
          addresses: result.addresses,
          expireAt: DateTime.now().add(result.ttl),
        );
        return result.addresses;
      }
    } catch (_) {}

    return InternetAddress.lookup(host, type: type);
  }

  Future<_SubLookupResult> _queryDoh(
    String host, {
    InternetAddressType type = InternetAddressType.any,
  }) async {
    final List<_SubLookupResult> results = [];
    if (type == InternetAddressType.any || type == InternetAddressType.IPv4) {
      results.add(await _querySingle(host, 1));
    }
    if (type == InternetAddressType.any || type == InternetAddressType.IPv6) {
      results.add(await _querySingle(host, 28));
    }

    final List<InternetAddress> addresses =
        results.expand((r) => r.addresses).toSet().toList(growable: false);
    if (addresses.isEmpty) {
      return _SubLookupResult.empty();
    }

    final Duration ttl = results.map((r) => r.ttl).reduce((a, b) => a < b ? a : b);
    return _SubLookupResult(addresses: addresses, ttl: ttl);
  }

  Future<_SubLookupResult> _querySingle(String host, int recordType) async {
    if (_dohEndpoint.trim().isEmpty) {
      return _SubLookupResult.empty();
    }

    final Uri base = Uri.parse(_dohEndpoint);
    final Map<String, String> params = Map.of(base.queryParameters);
    params['name'] = host;
    params['type'] = recordType.toString();

    final Uri uri = base.replace(queryParameters: params);
    final Response response = await _dohClient.getUri(
      uri,
      options: Options(
        headers: {'accept': 'application/dns-json'},
        responseType: ResponseType.json,
      ),
    );

    final dynamic data = response.data;
    if (data is! Map) {
      return _SubLookupResult.empty();
    }

    final int? status = (data['Status'] as num?)?.toInt();
    if (status != null && status != 0) {
      return _SubLookupResult.empty();
    }

    final List answers = data['Answer'] as List? ?? const [];
    final List<InternetAddress> addresses = [];
    int? minTtl;
    for (final dynamic answer in answers) {
      if (answer is! Map) {
        continue;
      }

      final int? typeValue = (answer['type'] as num?)?.toInt();
      if (typeValue != recordType) {
        continue;
      }

      final String? dataStr = answer['data'] as String?;
      if (dataStr == null) {
        continue;
      }

      final InternetAddress? address = InternetAddress.tryParse(dataStr);
      if (address == null) {
        continue;
      }
      addresses.add(address);

      final int? ttl = (answer['TTL'] as num?)?.toInt();
      if (ttl != null && ttl > 0) {
        minTtl = minTtl == null ? ttl : min(minTtl, ttl);
      }
    }

    if (addresses.isEmpty) {
      return _SubLookupResult.empty();
    }

    final int minTtlSeconds = minTtl == null || minTtl <= 0 ? _defaultTtl.inSeconds : minTtl;
    return _SubLookupResult(
      addresses: addresses,
      ttl: Duration(seconds: minTtlSeconds),
    );
  }
}

class _SubLookupResult {
  _SubLookupResult({required this.addresses, required this.ttl});

  factory _SubLookupResult.empty() =>
      _SubLookupResult(addresses: const [], ttl: SubIsolateManager._defaultTtl);

  final List<InternetAddress> addresses;
  final Duration ttl;
}

class _SubDnsCacheEntry {
  _SubDnsCacheEntry({required this.addresses, required this.expireAt});

  final List<InternetAddress> addresses;
  final DateTime expireAt;
}

SocksProxyConfiguration? _buildSocksConfig(ProxyConfig? config) {
  if (config == null || config.type != ProxyType.socks5) {
    return null;
  }

  return parseSocksProxyConfiguration(
    config.address,
    username: config.username,
    password: config.password,
  );
}

void subIsolateEntryPoint(SendPort mainSendPort) {
  SubIsolateManager(mainSendPort: mainSendPort);
}
