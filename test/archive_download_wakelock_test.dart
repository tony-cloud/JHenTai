import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/service/archive_download_service.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/path_service.dart';
import 'package:jhentai/service/wakelock_service.dart';
import 'package:jhentai/setting/download_setting.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';
import 'package:jhentai/utils/speed_computer.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

class _FailingArchiveRequests extends EHRequest {
  final firstAttempt = Completer<void>();
  final failRequests = Completer<void>();
  int attempts = 0;

  @override
  Future<T> requestUnlockArchive<T>({
    required String url,
    required bool isOriginal,
    CancelToken? cancelToken,
    HtmlParser<T>? parser,
  }) async {
    attempts++;
    if (!firstAttempt.isCompleted) {
      firstAttempt.complete();
    }
    await failRequests.future;
    throw DioException(
      requestOptions: RequestOptions(path: url),
      type: DioExceptionType.connectionError,
      message: 'archive download page unavailable',
    );
  }
}

class _NativeWakelock extends WakelockPlusPlatformInterface {
  bool awake = false;
  final toggles = <bool>[];
  final enabledOnce = Completer<void>();
  final disabledOnce = Completer<void>();

  @override
  Future<bool> get enabled async => awake;

  @override
  Future<void> toggle({required bool enable}) async {
    awake = enable;
    toggles.add(enable);
    final completion = enable ? enabledOnce : disabledOnce;
    if (!completion.isCompleted) {
      completion.complete();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'exhausted download page retries pause the archive and release the wakelock',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('archive-wakelock-');
    final previousDb = appDb;
    final previousRequests = ehRequest;
    final previousGallery = galleryDownloadService;
    final previousWakelock = wakelockService;
    final previousPath = pathService;
    final previousSettings = downloadSetting;
    final previousPlatform = wakelockPlusPlatformInstance;
    final previousDbWarning =
        driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    final requests = _FailingArchiveRequests();
    final native = _NativeWakelock();
    final service = ArchiveDownloadService();
    Future<void>? running;

    pathService = PathService()
      ..tempDir = directory
      ..appDocDir = directory
      ..appSupportDir = directory
      ..systemDownloadDir = directory;
    downloadSetting = DownloadSetting()..downloadPath = directory.path.obs;
    downloadSetting.keepScreenOnWhileDownloading.value = true;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    appDb = AppDb.forTesting(NativeDatabase.memory());
    ehRequest = requests;
    galleryDownloadService = GalleryDownloadService();
    wakelockService = WakelockService();
    wakelockPlusPlatformInstance = native;
    addTearDown(() async {
      if (!requests.failRequests.isCompleted) {
        requests.failRequests.complete();
      }
      await running;
      for (final info in service.archiveDownloadInfos.values) {
        info.speedComputer.dispose();
      }
      await wakelockService.release('download');
      wakelockService.onClose();
      await wakelockService.release('test-barrier');
      await appDb.close();
      appDb = previousDb;
      ehRequest = previousRequests;
      galleryDownloadService = previousGallery;
      wakelockService = previousWakelock;
      pathService = previousPath;
      downloadSetting = previousSettings;
      wakelockPlusPlatformInstance = previousPlatform;
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousDbWarning;
      await directory.delete(recursive: true);
    });

    final archive = ArchiveDownloadedData(
      gid: 1,
      token: 'token',
      title: 'archive',
      category: 'Manga',
      pageCount: 1,
      galleryUrl: 'https://example.test/g/1/token',
      coverUrl: '',
      size: 1024,
      publishTime: '2026-10-26',
      archiveStatusCode: ArchiveStatus.unlocked.code,
      archivePageUrl: 'https://example.test/archive/1',
      isOriginal: true,
      insertTime: '2026-10-26 00:00:00',
      sortOrder: 0,
      groupName: 'default',
      tags: '',
      parseSource: ArchiveParseSource.official.code,
    );
    await appDb.into(appDb.archiveDownloaded).insert(archive);
    final info = ArchiveDownloadInfo(
      size: archive.size,
      parseSource: archive.parseSource,
      archiveStatus: ArchiveStatus.unlocked,
      cancelToken: CancelToken(),
      speedComputer: SpeedComputer(),
      sortOrder: 0,
      group: 'default',
    );
    service
      ..archives = [archive]
      ..archiveDownloadInfos = {archive.gid: info};

    running = service.downloadArchive(archive, resume: true);
    await requests.firstAttempt.future.timeout(const Duration(seconds: 5));
    await native.enabledOnce.future.timeout(const Duration(seconds: 5));
    expect(info.archiveStatus, ArchiveStatus.parsingDownloadPageUrl);
    expect(wakelockService.isHeld('download'), isTrue);
    expect(native.awake, isTrue);

    requests.failRequests.complete();
    await running.timeout(const Duration(seconds: 5));
    expect(requests.attempts, 3);
    expect(info.archiveStatus, ArchiveStatus.paused);
    expect(info.cancelToken.isCancelled, isTrue);
    expect(info.downloadTask, isNull);
    expect(info.downloadCompleter, isNull);
    final stored = await appDb.select(appDb.archiveDownloaded).getSingle();
    expect(stored.archiveStatusCode, ArchiveStatus.paused.code);
    await native.disabledOnce.future.timeout(const Duration(seconds: 5));
    expect(wakelockService.hasAny, isFalse);
    expect(native.awake, isFalse);
    expect(native.toggles, [true, false]);
  });
}
