import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:integral_isolates/integral_isolates.dart';
import 'package:jhentai/database/dao/gallery_dao.dart';
import 'package:jhentai/database/dao/gallery_image_dao.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/model/gallery_image.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/isolate_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/service/path_service.dart';
import 'package:jhentai/service/wakelock_service.dart';
import 'package:jhentai/setting/download_setting.dart';
import 'package:jhentai/utils/eh_executor.dart';
import 'package:logger/logger.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late Directory logDirectory;
  late String? previousLogPath;
  late AppDb previousDatabase;
  late PathService previousPathService;
  late IsolateService previousIsolateService;
  late WakelockService previousWakelockService;
  late WakelockPlusPlatformInterface previousPlatform;
  late DownloadSetting previousSettings;
  late _ObservedDownloadService service;
  late _WakelockPlatform platform;

  setUpAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    logDirectory =
        await Directory.systemTemp.createTemp('jhentai-wakelock-logs-');
    previousLogPath = log.logDirPath;
    log.logDirPath = logDirectory.path;
  });
  tearDownAll(() async {
    // Logging is async-void; wait for a sentinel before closing its outputs.
    final drained = Completer<void>();
    void onOutput(OutputEvent event) {
      if (event.origin.message == 'Wakelock tests finished' &&
          !drained.isCompleted) {
        drained.complete();
      }
    }

    Logger.addOutputListener(onOutput);
    log.info('Wakelock tests finished');
    await drained.future;
    Logger.removeOutputListener(onOutput);
    await log.clear();
    log.logDirPath = previousLogPath;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('jhentai-wakelock-');
    previousPathService = pathService;
    pathService = PathService()
      ..tempDir = directory
      ..appDocDir = directory
      ..appSupportDir = directory
      ..systemDownloadDir = directory;
    previousSettings = downloadSetting;
    downloadSetting = DownloadSetting()..downloadPath = directory.path.obs;
    downloadSetting.keepScreenOnWhileDownloading.value = true;
    previousDatabase = appDb;
    appDb = AppDb.forTesting(NativeDatabase.memory());
    previousIsolateService = isolateService;
    isolateService = _PendingIsolateService();
    previousWakelockService = wakelockService;
    wakelockService = WakelockService();
    previousPlatform = wakelockPlusPlatformInstance;
    platform = _WakelockPlatform();
    wakelockPlusPlatformInstance = platform;
    service = _ObservedDownloadService()..executor = EHExecutor();
    await appDb.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async {
    await service.executor.close();
    for (final info in service.galleryDownloadInfos.values) {
      info.speedComputer.dispose();
    }
    await wakelockService.release('download');
    wakelockService.onClose();
    await wakelockService.release('test-barrier');
    wakelockService = previousWakelockService;
    wakelockPlusPlatformInstance = previousPlatform;
    await appDb.close();
    appDb = previousDatabase;
    isolateService = previousIsolateService;
    pathService = previousPathService;
    downloadSetting = previousSettings;
    await directory.delete(recursive: true);
  });

  for (final pageCount in [2, 0]) {
    test('resumed complete gallery with $pageCount pages releases wakelock',
        () async {
      final gallery = _gallery(pageCount);
      await GalleryDao.insertGallery(gallery.toCompanion(true));
      for (int serialNo = 0; serialNo < pageCount; serialNo++) {
        await GalleryImageDao.insertImage(ImageData(
          gid: gallery.gid,
          url: 'https://example.com/$serialNo.jpg',
          serialNo: serialNo,
          path: '$serialNo.jpg',
          imageHash: '',
          downloadStatusIndex: DownloadStatus.downloaded.index,
        ));
      }

      // Reproduce startup restoration: every image is downloaded, while the
      // persisted gallery still says downloading.
      final images =
          (await GalleryImageDao.selectImagesByGalleryId(gallery.gid))
              .map(GalleryImage.fromImageData)
              .toList();
      service.gallerys = [gallery];
      service.galleryDownloadInfos[gallery.gid] = _info(gallery, images);

      await service.downloadGallery(gallery, resume: true);
      await service.downloadSucceeded.future
          .timeout(const Duration(seconds: 5));
      await service.executor.join(withWaiting: true);
      await (isolateService as _PendingIsolateService).entered.future;
      // Drain the real service's queued native enable/release operations.
      await wakelockService.release('test-barrier');

      final info = service.galleryDownloadInfos[gallery.gid]!;
      expect(info.downloadProgress.curCount, pageCount);
      expect(info.downloadProgress.downloadStatus, DownloadStatus.downloaded);
      expect(service.gallerys.single.downloadStatusIndex,
          DownloadStatus.downloaded.index);
      expect((await GalleryDao.selectGallerys()).single.downloadStatusIndex,
          DownloadStatus.downloaded.index);
      expect(info.tasks, isEmpty);
      expect(service.executor.scheduledCount, 0);
      expect(info.speedComputer.isActive(), isFalse);
      expect(service.updatedIds,
          contains('${service.galleryDownloadProgressId}::${gallery.gid}'));
      expect(wakelockService.activeLocks, isEmpty);
      expect(platform.toggles, [true, false]);
      expect(await platform.enabled, isFalse);
    });
  }
}

GalleryDownloadedData _gallery(int pageCount) => GalleryDownloadedData(
      gid: 1,
      token: '0123456789',
      title: 'Restored gallery',
      category: 'Manga',
      pageCount: pageCount,
      galleryUrl: 'https://e-hentai.org/g/1/0123456789/',
      publishTime: '2026-01-01 00:00:00',
      downloadStatusIndex: DownloadStatus.downloading.index,
      insertTime: '2026-01-01 00:00:00',
      downloadOriginalImage: false,
      priority: GalleryDownloadService.defaultDownloadGalleryPriority,
      sortOrder: 0,
      groupName: 'default'.tr,
      tags: '',
    );

GalleryDownloadInfo _info(
        GalleryDownloadedData gallery, List<GalleryImage> images) =>
    GalleryDownloadInfo(
      thumbnailsCountPerPage: 20,
      tasks: [],
      cancelToken: CancelToken(),
      downloadProgress: GalleryDownloadProgress(
        curCount: images.length,
        totalCount: gallery.pageCount,
        downloadStatus: DownloadStatus.downloading,
        hasDownloaded: List.filled(gallery.pageCount, true),
      ),
      imageHrefs: List.filled(gallery.pageCount, null),
      images: images,
      preferOriginalImages: List.filled(gallery.pageCount, false),
      legacyReloadKeyHistory:
          List.generate(gallery.pageCount, (_) => <String>{}),
      legacyReloadTriedWithoutKey: List.filled(gallery.pageCount, false),
      speedComputer: GalleryDownloadSpeedComputer(gallery.pageCount, () {}),
      priority: gallery.priority,
      sortOrder: gallery.sortOrder,
      group: gallery.groupName,
      mpvImageKeys: List.filled(gallery.pageCount, null),
      mpvSkipServerIdentifiers: List.filled(gallery.pageCount, null),
    );

class _ObservedDownloadService extends GalleryDownloadService {
  final Completer<void> downloadSucceeded = Completer<void>();
  final List<Object> updatedIds = [];

  @override
  void update([List<Object>? ids, bool condition = true]) {
    if (ids != null) {
      updatedIds.addAll(ids);
      if (ids.contains('$galleryDownloadSuccessId::1') &&
          !downloadSucceeded.isCompleted) {
        downloadSucceeded.complete();
      }
    }
    super.update(ids, condition);
  }
}

class _WakelockPlatform extends WakelockPlusPlatformInterface {
  bool _enabled = false;
  final List<bool> toggles = [];

  @override
  Future<bool> get enabled async => _enabled;

  @override
  Future<void> toggle({required bool enable}) async {
    toggles.add(enable);
    _enabled = enable;
  }
}

// Keep optional metadata serialization pending so this regression exercises
// executor/status/wakelock cleanup without unrelated filesystem writes.
class _PendingIsolateService extends IsolateService {
  final Completer<void> entered = Completer<void>();

  @override
  Future<R> run<Q, R>(IsolateCallback<Q, R> callback, Q message,
      {String? debugLabel}) {
    if (!entered.isCompleted) {
      entered.complete();
    }
    return Completer<R>().future;
  }
}
