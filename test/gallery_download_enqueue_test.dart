import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:executor/executor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:integral_isolates/integral_isolates.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/model/gallery_url.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/isolate_service.dart';
import 'package:jhentai/service/path_service.dart';
import 'package:jhentai/setting/download_setting.dart';
import 'package:jhentai/utils/eh_executor.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late AppDb previousDatabase;
  late IsolateService previousIsolateService;
  late _DownloadService service;
  late _CountingInfos infos;

  setUpAll(() {
    // Each test uses its own in-memory executor; the unopened app singleton
    // remains separate and is restored after the test.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('jhentai-enqueue-');
    pathService
      ..tempDir = directory
      ..appDocDir = directory
      ..appSupportDir = directory
      ..systemDownloadDir = directory;
    downloadSetting.downloadPath = directory.path.obs;
    previousDatabase = appDb;
    appDb = AppDb.forTesting(NativeDatabase.memory());
    previousIsolateService = isolateService;
    isolateService = _PendingIsolateService();
    service = _DownloadService()..executor = _PendingExecutor();
    infos = _CountingInfos();
    service.galleryDownloadInfos = infos;
    await appDb.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async {
    for (final info in infos.values) {
      info.speedComputer.dispose();
    }
    await appDb.close();
    appDb = previousDatabase;
    isolateService = previousIsolateService;
    await directory.delete(recursive: true);
  });

  void seed(List<GalleryDownloadedData> galleries) {
    service.gallerys = galleries;
    for (final gallery in galleries) {
      infos[gallery.gid] = _info(gallery);
    }
  }

  test('single and repeated enqueue do not re-sort the existing library',
      () async {
    seed(List.generate(10000, (index) => _gallery(10000 - index)));

    for (int gid = 10001; gid <= 10003; gid++) {
      infos.reads = 0;
      final Stopwatch stopwatch = Stopwatch()..start();
      await service.downloadGallery(_gallery(gid));
      stopwatch.stop();
      final int reads = infos.reads;
      // A deterministic work bound, independent of machine speed. Inserting
      // one record needs only a binary search plus its own initialization.
      expect(reads, lessThan(100), reason: 'enqueue took ${stopwatch.elapsed}');
      expect(service.gallerys.first.gid, gid);
      expect(service.gallerys.length, gid);
      expect(service.containGallery(gid), isTrue);
      expect(
          (service.executor as _PendingExecutor).tasks, hasLength(gid - 10000));
    }

    await service.downloadGallery(_gallery(10003));
    expect(service.gallerys, hasLength(10003));
    expect((service.executor as _PendingExecutor).tasks, hasLength(3));
  });

  test('enqueue respects live groups, manual order, and newest-first dates',
      () async {
    seed([
      _gallery(1, group: 'A', order: -1),
      _gallery(3, group: 'A'),
      _gallery(2, group: 'A'),
      _gallery(4, group: 'A'),
      _gallery(5),
    ]);
    // Group/order changes are held in the live info, while rows may be stale.
    infos[4]!.group = 'B';
    infos[2]!.sortOrder = 1;

    await service.downloadGallery(_gallery(6, group: 'A'));
    await service.downloadGallery(_gallery(7, group: 'B'));
    await service.downloadGallery(_gallery(8));

    expect(service.gallerys.map((gallery) => gallery.gid),
        [1, 6, 3, 2, 7, 4, 8, 5]);
    expect(service.allGroups, containsAll(['A', 'B', 'default'.tr]));
  });

  test('starting a large gallery yields to input and observes a pause',
      () async {
    final gallery = _gallery(1).copyWith(pageCount: 2000);
    await service.downloadGallery(gallery);
    final executor = service.executor as _PendingExecutor;

    bool inputHandled = false;
    Timer.run(() {
      inputHandled = true;
      infos[1]!.downloadProgress.downloadStatus = DownloadStatus.paused;
    });
    await executor.tasks.first();

    expect(inputHandled, isTrue);
    expect(executor.tasks.length, greaterThan(1));
    expect(executor.tasks.length, lessThan(2001));
    final int expectedPriority =
        GalleryDownloadService.defaultDownloadGalleryPriority * 100000000 +
            101000001 * 2000;
    expect(executor.priorities.first, expectedPriority);
    expect(
        executor.priorities.skip(1),
        List.generate(
            executor.tasks.length - 1, (index) => expectedPriority + index));
  });
}

GalleryDownloadedData _gallery(int gid, {String? group, int order = 0}) {
  return GalleryDownloadedData(
    gid: gid,
    token: '0123456789',
    title: 'Gallery $gid',
    category: 'Manga',
    pageCount: 1,
    galleryUrl: 'https://e-hentai.org/g/$gid/0123456789/',
    publishTime: '2026-01-01 00:00:00',
    downloadStatusIndex: DownloadStatus.downloaded.index,
    insertTime: DateTime(2026).add(Duration(seconds: gid)).toString(),
    downloadOriginalImage: false,
    priority: GalleryDownloadService.defaultDownloadGalleryPriority,
    sortOrder: order,
    groupName: group ?? 'default'.tr,
    tags: '',
  );
}

GalleryDownloadInfo _info(GalleryDownloadedData gallery) {
  return GalleryDownloadInfo(
    thumbnailsCountPerPage: 20,
    tasks: [],
    cancelToken: CancelToken(),
    downloadProgress: GalleryDownloadProgress(
      curCount: 1,
      totalCount: 1,
      downloadStatus: DownloadStatus.downloaded,
      hasDownloaded: [true],
    ),
    imageHrefs: [null],
    images: [null],
    preferOriginalImages: [false],
    legacyReloadKeyHistory: [{}],
    legacyReloadTriedWithoutKey: [false],
    speedComputer: GalleryDownloadSpeedComputer(1, () {}),
    priority: gallery.priority,
    sortOrder: gallery.sortOrder,
    group: gallery.groupName,
    mpvImageKeys: [null],
    mpvSkipServerIdentifiers: [null],
  );
}

class _CountingInfos extends MapBase<int, GalleryDownloadInfo> {
  final Map<int, GalleryDownloadInfo> _values = {};
  int reads = 0;

  @override
  GalleryDownloadInfo? operator [](Object? key) {
    reads++;
    return _values[key];
  }

  @override
  void operator []=(int key, GalleryDownloadInfo value) => _values[key] = value;
  @override
  Iterable<int> get keys => _values.keys;
  @override
  Iterable<GalleryDownloadInfo> get values => _values.values;
  @override
  void clear() => _values.clear();
  @override
  GalleryDownloadInfo? remove(Object? key) => _values.remove(key);
}

class _DownloadService extends GalleryDownloadService {
  @override
  Future<({GalleryUrl galleryUrl, T detailPageInfo})>
      requestGalleryDetailWithExFallback<T>({
    required GalleryUrl galleryUrl,
    int thumbnailsPageIndex = 0,
    CancelToken? cancelToken,
    bool useCacheIfAvailable = true,
    required HtmlParser<T> parser,
    String logContext = 'Gallery detail',
    void Function(Object)? onRetry,
  }) =>
          Completer<({GalleryUrl galleryUrl, T detailPageInfo})>().future;
}

class _PendingExecutor extends Fake implements EHExecutor {
  final List<AsyncTask> tasks = [];
  final List<int> priorities = [];

  @override
  Future<R> scheduleTask<R>(int priority, AsyncTask<R> task) {
    tasks.add(task);
    priorities.add(priority);
    return Completer<R>().future;
  }
}

// Keep optional metadata/network work pending to measure the real registration
// and queueing path without external services or unrelated file writes.
class _PendingIsolateService extends IsolateService {
  @override
  Future<R> run<Q, R>(IsolateCallback<Q, R> callback, Q message,
          {String? debugLabel}) =>
      Completer<R>().future;
}
