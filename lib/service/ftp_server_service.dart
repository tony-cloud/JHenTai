import 'dart:async';
import 'dart:io';

import 'package:ftp_server/ftp_server.dart';
import 'package:ftp_server/file_operations/physical_file_operations.dart';
import 'package:ftp_server/server_type.dart';
import 'package:get/get.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../setting/download_setting.dart';
import '../setting/ftp_server_setting.dart';
import '../utils/toast_util.dart';
import 'jh_service.dart';
import 'log.dart';
import 'path_service.dart';

FtpServerService ftpServerService = FtpServerService();

class FtpServerService extends GetxService
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  final RxBool serverRunning = false.obs;

  FtpServer? _server;
  Worker? _enableWorker;
  Worker? _restartWorker;
  Worker? _downloadPathWorker;
  Worker? _keepScreenWorker;

  Future<void> _serialTask = Future.value();
  bool _wakelockEnabledByService = false;

  @override
  List<JHLifeCircleBean> get initDependencies =>
      [pathService, log, ftpServerSetting, downloadSetting];

  Future<void> _enqueue(Future<void> Function() action) {
    _serialTask = _serialTask.then((_) => action()).catchError((error, stack) {
      log.error('FTP server task failed', error, stack);
    });
    return _serialTask;
  }

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);

    _enableWorker = ever(ftpServerSetting.enableServer, (_) => _syncServerState());
    _restartWorker = everAll(
      [
        ftpServerSetting.port,
        ftpServerSetting.username,
        ftpServerSetting.password,
        ftpServerSetting.allowReadAndWrite
      ],
      (_) => _restartIfRunning(),
    );
    _downloadPathWorker = ever(downloadSetting.downloadPath, (_) => _restartIfRunning());
    _keepScreenWorker = ever(ftpServerSetting.keepScreenOn, (_) => _enqueue(_syncWakelock));

    if (ftpServerSetting.enableServer.isTrue) {
      await _startServer();
    }
  }

  @override
  Future<void> doAfterBeanReady() async {}

  Future<void> _syncServerState() => _enqueue(() async {
        if (ftpServerSetting.enableServer.isTrue) {
          await _startServer();
        } else {
          await _stopServer();
        }
      });

  Future<void> _restartIfRunning() => _enqueue(() async {
        if (ftpServerSetting.enableServer.isFalse) {
          return;
        }
        await _stopServer();
        await _startServer();
      });

  Future<void> _startServer() async {
    await _stopServer();

    final String rootPath = downloadSetting.downloadPath.value;
    try {
      await Directory(rootPath).create(recursive: true);
    } on Exception catch (e, stack) {
      log.error('Failed to create FTP root directory: $rootPath', e, stack);
      toast('${'ftpServerStartFailed'.tr}: $e', isCenter: false);
      await ftpServerSetting.saveEnableServer(false);
      return;
    }

    final FtpServer server = FtpServer(
      ftpServerSetting.port.value,
      username: ftpServerSetting.username.value.trim().isEmpty
          ? null
          : ftpServerSetting.username.value.trim(),
      password: ftpServerSetting.password.value.isEmpty ? null : ftpServerSetting.password.value,
      fileOperations: PhysicalFileOperations(rootPath),
      serverType:
          ftpServerSetting.allowReadAndWrite.isTrue ? ServerType.readAndWrite : ServerType.readOnly,
      logFunction: (message) => log.info('[FTP] $message'),
    );

    try {
      await server.startInBackground();
      _server = server;
      serverRunning.value = true;
      log.info('FTP server started on port ${ftpServerSetting.port.value} serving $rootPath');
      await _syncWakelock();
    } on SocketException catch (e, stack) {
      log.error('Failed to start FTP server due to socket error', e, stack);
      toast('${'ftpServerStartFailed'.tr}: ${e.message}', isCenter: false);
      await ftpServerSetting.saveEnableServer(false);
    } on Exception catch (e, stack) {
      log.error('Failed to start FTP server', e, stack);
      toast('${'ftpServerStartFailed'.tr}: $e', isCenter: false);
      await ftpServerSetting.saveEnableServer(false);
    }
  }

  Future<void> _stopServer() async {
    if (_server == null) {
      serverRunning.value = false;
      await _syncWakelock();
      return;
    }

    final FtpServer? server = _server;
    _server = null;
    serverRunning.value = false;

    try {
      await server?.stop();
      log.info('FTP server stopped');
    } on Exception catch (e, stack) {
      log.error('Failed to stop FTP server', e, stack);
    }

    await _syncWakelock();
  }

  Future<void> _syncWakelock() async {
    final bool shouldKeepAwake = ftpServerSetting.keepScreenOn.isTrue && serverRunning.isTrue;

    if (shouldKeepAwake && !_wakelockEnabledByService) {
      try {
        final bool alreadyEnabled = await WakelockPlus.enabled;
        if (!alreadyEnabled) {
          await WakelockPlus.enable();
          _wakelockEnabledByService = true;
        }
      } on Exception catch (e, stack) {
        log.error('Enable wakelock for FTP server failed', e, stack);
      }
      return;
    }

    if (!shouldKeepAwake && _wakelockEnabledByService) {
      try {
        await WakelockPlus.disable();
      } on Exception catch (e, stack) {
        log.error('Disable wakelock for FTP server failed', e, stack);
      }
      _wakelockEnabledByService = false;
      return;
    }
  }

  @override
  void onClose() {
    _enableWorker?.dispose();
    _restartWorker?.dispose();
    _downloadPathWorker?.dispose();
    _keepScreenWorker?.dispose();
    _server?.stop().ignore();
    super.onClose();
  }
}
