import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

import 'package:jhentai/service/jh_service.dart';

PathService pathService = PathService();

class PathService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  /// visible for all
  late Directory tempDir;

  /// visible on ios&windows&macos
  Directory? appDocDir;

  /// visible on windows
  Directory? appSupportDir;

  /// visible on android
  Directory? externalStorageDir;

  Directory? systemDownloadDir;

  bool get isInitialized {
    try {
      return tempDir.path.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  List<JHLifeCircleBean> get initDependencies => [];

  @override
  Future<void> doInitBean() async {
    if (kIsWeb) {
      tempDir = Directory('/web-temp');
      appDocDir = Directory('/web-documents');
      appSupportDir = Directory('/web-support');
      externalStorageDir = null;
      systemDownloadDir = Directory('/web-downloads');
      return;
    }

    tempDir = await getTemporaryDirectory();
    appDocDir = await _tryGetDirectory(getApplicationDocumentsDirectory);
    appSupportDir = await _tryGetDirectory(getApplicationSupportDirectory);
    externalStorageDir = await _tryGetDirectory(getExternalStorageDirectory);
    systemDownloadDir = await _tryGetDirectory(getDownloadsDirectory);

    systemDownloadDir ??= appDocDir ?? appSupportDir ?? tempDir;
  }

  @override
  Future<void> doAfterBeanReady() async {}

  Directory getVisibleDir() {
    if (GetPlatform.isAndroid && externalStorageDir != null) {
      return externalStorageDir!;
    }
    if (GetPlatform.isWindows && appSupportDir != null) {
      return appSupportDir!;
    }
    if (GetPlatform.isLinux && appSupportDir != null) {
      return appSupportDir!;
    }
    return appDocDir ?? appSupportDir ?? systemDownloadDir!;
  }
}

Future<Directory?> _tryGetDirectory(Future<Directory?> Function() getter) async {
  try {
    return await getter();
  } catch (_) {
    return null;
  }
}
