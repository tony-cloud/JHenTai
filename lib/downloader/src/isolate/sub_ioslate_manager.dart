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
import 'package:jhentai/network/doh_resolver.dart';

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
  late final DohResolver _dohResolver;

  bool _enableDoh = false;
  String _dohEndpoint = '';

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
                List<String> autoDohEndpoints,
              })>;
          _proxyConfig = message.data.proxyConfig;
          _enableDoh = message.data.enableDoh;
          _dohEndpoint = message.data.dohEndpoint;
          _dohResolver = DohResolver(
            dio: _dohClient,
            autoEndpoints: message.data.autoDohEndpoints,
          );
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
                int fileWriteOffset,
                Duration connectionTimeout,
                Duration receiveTimeout,
                int timeoutRetryTimes,
              })>;
          download(
            message.data.url,
            message.data.downloadPath,
            message.data.downloadRange,
            message.data.fileWriteOffset,
            message.data.connectionTimeout,
            message.data.receiveTimeout,
            message.data.timeoutRetryTimes,
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

  Future<void> download(
      String url,
      String downloadPath,
      ({int start, int end}) downloadRange,
      int fileWriteOffset,
      Duration connectionTimeout,
      Duration receiveTimeout,
      int timeoutRetryTimes) async {
    final CancelToken cancelToken = CancelToken();
    _cancelToken = cancelToken;
    RandomAccessFile? file;
    JDownloadException? failure;
    bool cancelled = false;
    int received = 0;
    _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.begin, null));
    try {
      file = await File(downloadPath).open(mode: FileMode.writeOnlyAppend);
      await file.setPosition(fileWriteOffset);
      int retriesWithoutProgress = 0;
      while (received < downloadRange.end - downloadRange.start) {
        if (cancelToken.isCancelled) {
          throw cancelToken.cancelError!;
        }
        // A fresh client releases the stalled socket before resuming the range.
        final Dio client = Dio(BaseOptions(
          connectTimeout: connectionTimeout,
          sendTimeout: connectionTimeout,
          receiveTimeout: receiveTimeout,
        ));
        try {
          final int start = downloadRange.start + received;
          final Response<ResponseBody> response = await client.get<ResponseBody>(
            url,
            options: Options(
              // Preserve the archive endpoint's legacy Range wire format.
              preserveHeaderCase: true,
              headers: {'Range': '$start-${downloadRange.end - 1}'},
              responseType: ResponseType.stream,
            ),
            cancelToken: cancelToken,
          );
          if (response.statusCode != HttpStatus.partialContent) {
            throw JDownloadException(JDownloadExceptionType.serverNotSupport,
                error: StateError('Expected HTTP 206 for archive range '
                    '$start-${downloadRange.end - 1}, received HTTP ${response.statusCode}'));
          }
          // Also cover a server that sends headers but never sends the first
          // body byte. This is an idle timeout, not a total download deadline.
          final Stream<Uint8List> stream = receiveTimeout > Duration.zero
              ? response.data!.stream.timeout(receiveTimeout, onTimeout: (sink) {
                  sink.addError(DioException.receiveTimeout(
                    timeout: receiveTimeout,
                    requestOptions: response.requestOptions,
                  ));
                  sink.close();
                })
              : response.data!.stream;
          await for (final Uint8List data in stream) {
            if (cancelToken.isCancelled) {
              throw cancelToken.cancelError!;
            }
            if (received + data.length > downloadRange.end - downloadRange.start) {
              throw JDownloadException(JDownloadExceptionType.receiveDataFailed,
                  error: StateError('Archive range response exceeds requested length'));
            }
            try {
              await file.writeFrom(data);
            } on FileSystemException catch (e) {
              throw JDownloadException(JDownloadExceptionType.writeDownloadFileFailed, error: e);
            }
            received += data.length;
            if (data.isNotEmpty) {
              retriesWithoutProgress = 0;
            }
            _mainSendPort.send(SubIsolateMessage<int>(SubIsolateMessageType.progress, data.length));
          }
          if (received != downloadRange.end - downloadRange.start) {
            throw JDownloadException(JDownloadExceptionType.receiveDataFailed,
                error: StateError('Incomplete archive range response'));
          }
        } catch (error) {
          if (cancelToken.isCancelled ||
              !_isRetryableNetworkError(error) ||
              retriesWithoutProgress >= timeoutRetryTimes) {
            rethrow;
          }
          // Close before backoff; pausing must cancel the wait immediately.
          client.close(force: true);
          final Duration delay = Duration(seconds: 1 << min(retriesWithoutProgress++, 4));
          _mainSendPort.send(SubIsolateMessage(
              SubIsolateMessageType.log,
              LogEvent(
                  Level.warning,
                  'Archive range stalled; retry '
                  '$retriesWithoutProgress/$timeoutRetryTimes in ${delay.inSeconds}s '
                  'from byte ${downloadRange.start + received}: $error')));
          final Completer<void> waiting = Completer<void>();
          final Timer timer = Timer(delay, waiting.complete);
          try {
            await Future.any([waiting.future, cancelToken.whenCancel]);
          } finally {
            timer.cancel();
          }
        } finally {
          client.close(force: true);
        }
      }
      await file.flush();
    } on JDownloadException catch (e) {
      failure = e;
    } on DioException catch (e) {
      cancelled = e.type == DioExceptionType.cancel;
      if (!cancelled) {
        e.response?.data = null;
        e.requestOptions.cancelToken = null;
        failure = JDownloadException(JDownloadExceptionType.downloadFailed, error: e);
      }
    } catch (e) {
      failure = JDownloadException(
          e is FileSystemException
              ? JDownloadExceptionType.writeDownloadFileFailed
              : JDownloadExceptionType.receiveDataFailed,
          error: e);
    } finally {
      try {
        await file?.close();
      } on FileSystemException catch (e) {
        failure ??= JDownloadException(JDownloadExceptionType.writeDownloadFileFailed, error: e);
      }
      _cancelToken = null;
    }
    if (cancelled || cancelToken.isCancelled) {
      _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.closeReady, null));
    } else if (failure != null) {
      _mainSendPort
          .send(SubIsolateMessage<JDownloadException>(SubIsolateMessageType.error, failure));
    } else {
      _mainSendPort.send(SubIsolateMessage<Null>(SubIsolateMessageType.done, null));
    }
  }

  bool _isRetryableNetworkError(Object error) {
    if (error is SocketException || error is HttpException) {
      return true;
    }
    return error is DioException &&
        (error.type == DioExceptionType.connectionTimeout ||
            error.type == DioExceptionType.sendTimeout ||
            error.type == DioExceptionType.receiveTimeout ||
            error.type == DioExceptionType.connectionError ||
            (error.type == DioExceptionType.unknown && error.error is SocketException));
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

    try {
      return await _dohResolver.lookup(host, endpoint: _dohEndpoint, type: type);
    } catch (_) {
      return InternetAddress.lookup(host, type: type);
    }
  }
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
