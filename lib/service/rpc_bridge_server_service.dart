import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:jhentai/rpc_bridge/rpc_bridge_server.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/service/rpc_service.dart';
import 'package:jhentai/setting/rpc_setting.dart';

RPCBridgeServerService rpcBridgeServerService = RPCBridgeServerService();

class RPCBridgeServerService extends GetxService
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  final RxBool serverRunning = false.obs;
  final RxnString serverError = RxnString();

  RpcBridgeServer? _server;
  Worker? _enableWorker;
  Worker? _restartWorker;
  Future<void> _serialTask = Future<void>.value();

  @override
  List<JHLifeCircleBean> get initDependencies =>
      [rpcSetting, rpcService, ...super.initDependencies];

  Future<void> _enqueue(Future<void> Function() action) {
    _serialTask = _serialTask.then((_) => action()).catchError((Object error, StackTrace stack) {
      log.error('RPC bridge server task failed', error, stack);
    });
    return _serialTask;
  }

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);

    if (kIsWeb) {
      return;
    }

    _enableWorker = ever(
      rpcSetting.enableEmbeddedServer,
      (_) => _syncServerState(),
    );

    _restartWorker = everAll(
      [
        rpcSetting.embeddedHost,
        rpcSetting.embeddedPort,
        rpcSetting.embeddedAuthRequired,
        rpcSetting.embeddedToken,
      ],
      (_) => _restartIfRunning(),
    );

    if (rpcSetting.enableEmbeddedServer.isTrue) {
      await _startServer();
    }
  }

  @override
  Future<void> doAfterBeanReady() async {}

  Future<void> _syncServerState() {
    return _enqueue(() async {
      if (rpcSetting.enableEmbeddedServer.isTrue) {
        await _startServer();
      } else {
        await _stopServer();
      }
    });
  }

  Future<void> _restartIfRunning() {
    return _enqueue(() async {
      if (rpcSetting.enableEmbeddedServer.isFalse || serverRunning.isFalse) {
        return;
      }

      await _stopServer();
      await _startServer();
    });
  }

  Future<void> _startServer() async {
    await _stopServer();

    final String host = rpcSetting.embeddedHost.value.trim();
    final int port = rpcSetting.embeddedPort.value;
    final String token =
        rpcSetting.embeddedAuthRequired.isTrue ? rpcSetting.embeddedToken.value.trim() : '';

    final RpcBridgeServer server = RpcBridgeServer(
      host: host,
      port: port,
      authToken: token,
      cookieHeader: '',
      certificatePath: '',
      privateKeyPath: '',
      privateKeyPassword: '',
    );

    try {
      await server.start();
      _server = server;
      serverRunning.value = true;
      serverError.value = null;
      log.info(
        'RPC bridge server started on '
        '${server.tlsEnabled ? 'https' : 'http'}://$host:$port',
      );

      await rpcService.checkHealth();
    } on SocketException catch (e, stack) {
      log.error('Failed to start RPC bridge server due to socket error', e, stack);
      serverError.value = e.message;
      await rpcSetting.saveEnableEmbeddedServer(false);
    } on Exception catch (e, stack) {
      log.error('Failed to start RPC bridge server', e, stack);
      serverError.value = e.toString();
      await rpcSetting.saveEnableEmbeddedServer(false);
    }
  }

  Future<void> _stopServer() async {
    final RpcBridgeServer? server = _server;
    _server = null;

    if (server == null) {
      serverRunning.value = false;
      return;
    }

    try {
      await server.stop();
      log.info('RPC bridge server stopped');
    } on Exception catch (e, stack) {
      log.error('Failed to stop RPC bridge server', e, stack);
    }

    serverRunning.value = false;
  }

  @override
  void onClose() {
    _enableWorker?.dispose();
    _restartWorker?.dispose();
    _server?.stop().ignore();
    super.onClose();
  }
}
