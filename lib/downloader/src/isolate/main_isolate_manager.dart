import 'dart:async';
import 'dart:isolate';

import 'package:logger/logger.dart';

import 'package:jhentai/downloader/src/exception/j_download_exception.dart';
import 'package:jhentai/downloader/src/isolate/sub_ioslate_manager.dart';
import 'package:jhentai/downloader/src/model/main_isolate_message.dart';
import 'package:jhentai/downloader/src/model/proxy_config.dart';
import 'package:jhentai/downloader/src/model/sub_isolate_message.dart';
import 'package:jhentai/downloader/src/function/function.dart';
import 'package:jhentai/service/log.dart';

class MainIsolateManager {
  final ProxyConfig? _proxyConfig;
  final bool _enableDoh;
  final String _dohEndpoint;

  bool _ready = false;

  bool get ready => _ready;
  Isolate? _isolate;
  ReceivePort? _mainReceivePort;
  SendPort? _subSendPort;

  bool _free = true;

  bool get free => _free;

  VoidCallback? _onReady;
  ValueCallback? _onProgress;
  VoidCallback? _onDone;
  ValueCallback<JDownloadException>? _onError;

  Completer<void>? _closeCompleter;
  bool _closing = false;

  MainIsolateManager({
    ProxyConfig? proxyConfig,
    required bool enableDoh,
    required String? dohEndpoint,
  })  : _proxyConfig = proxyConfig,
        _enableDoh = enableDoh,
        _dohEndpoint = dohEndpoint ?? '';

  Future<void> initIsolate() async {
    if (_ready) {
      return;
    }

    _closing = false;
    _mainReceivePort = ReceivePort();

    try {
      _isolate = await Isolate.spawn(subIsolateEntryPoint, _mainReceivePort!.sendPort);
    } catch (e) {
      _mainReceivePort!.close();
      rethrow;
    }

    _isolate!.addOnExitListener(_mainReceivePort!.sendPort);

    _mainReceivePort!.listen((message) {
      if (message == null && !_closing) {
        _onError?.call(JDownloadException(JDownloadExceptionType.downloadFailed,
            error: StateError('Download worker exited unexpectedly')));
      }
      message ??= SubIsolateMessage<Null>(SubIsolateMessageType.closed, null);

      if (message.type != SubIsolateMessageType.log) {
        log.download(message,
            level: message.type == SubIsolateMessageType.progress ? Level.trace : Level.debug);
      }

      switch (message.type) {
        case SubIsolateMessageType.created:
          message = message as SubIsolateMessage<SendPort>;
          _subSendPort = message.data;
          _subSendPort!.send(
            MainIsolateMessage<
                ({
                  ProxyConfig? proxyConfig,
                  bool enableDoh,
                  String dohEndpoint,
                })>(
              MainIsolateMessageType.init,
              (
                proxyConfig: _proxyConfig,
                enableDoh: _enableDoh,
                dohEndpoint: _dohEndpoint,
              ),
            ),
          );
          break;
        case SubIsolateMessageType.inited:
          _ready = true;
          _free = true;
          _onReady?.call();
          break;
        case SubIsolateMessageType.progress:
          message = message as SubIsolateMessage<int>;
          _onProgress?.call(message.data);
          break;
        case SubIsolateMessageType.error:
          message = message as SubIsolateMessage;
          _free = true;
          _onError?.call(message.data);
          break;
        case SubIsolateMessageType.done:
          _free = true;
          _onDone?.call();
        case SubIsolateMessageType.closeReady:
        case SubIsolateMessageType.closed:
          message = message as SubIsolateMessage<Null>;
          _mainReceivePort?.close();
          _isolate?.kill();
          _isolate = null;
          _subSendPort = null;
          _ready = false;
          _free = true;
          if (_closeCompleter?.isCompleted == false) {
            _closeCompleter!.complete();
          }
          _closeCompleter = null;
          break;
        case SubIsolateMessageType.log:
          message = message as SubIsolateMessage<LogEvent>;
          log.download(
            message.data.message,
            level: message.data.level,
            //time: message.data.time,
            error: message.data.error,
            stackTrace: message.data.stackTrace,
          );
          break;
        default:
          break;
      }
    });
  }

  void beginDownload(String url, String downloadPath, ({int start, int end}) downloadRange,
      int fileWriteOffset) {
    assert(_isolate != null && _mainReceivePort != null && _subSendPort != null && _ready);

    if (!_free) {
      return;
    }
    _free = false;

    _subSendPort!.send(
      MainIsolateMessage(
        MainIsolateMessageType.download,
        (
          url: url,
          downloadPath: downloadPath,
          downloadRange: downloadRange,
          fileWriteOffset: fileWriteOffset
        ),
      ),
    );
  }

  Future<void> killIsolate() async {
    if (_isolate == null || _mainReceivePort == null) {
      return;
    }
    if (_closing) {
      return _closeCompleter?.future;
    }
    _closing = true;
    _closeCompleter = Completer<void>();
    final Future<void> closed = _closeCompleter!.future;
    if (_subSendPort == null) {
      _isolate!.kill(priority: Isolate.immediate);
    } else {
      // Idle and failed workers still own ports and HTTP clients.
      _subSendPort!.send(MainIsolateMessage(MainIsolateMessageType.close, null));
    }
    await closed;
  }

  void registerOnReady(VoidCallback onReady) {
    _onReady = onReady;
  }

  void unRegisterOnReady() {
    _onReady = null;
  }

  void registerOnProgress(ValueCallback onProgress) {
    _onProgress = onProgress;
  }

  void unRegisterOnProgress() {
    _onProgress = null;
  }

  void registerOnDone(VoidCallback onDone) {
    _onDone = onDone;
  }

  void unRegisterOnDone() {
    _onDone = null;
  }

  void registerOnError(ValueCallback<JDownloadException> onError) {
    _onError = onError;
  }

  void unRegisterOnError() {
    _onError = null;
  }
}
