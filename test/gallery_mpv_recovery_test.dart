import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:executor/executor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:integral_isolates/integral_isolates.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/model/detail_page_info.dart';
import 'package:jhentai/model/gallery_thumbnail.dart';
import 'package:jhentai/model/gallery_url.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/isolate_service.dart';
import 'package:jhentai/service/path_service.dart';
import 'package:jhentai/setting/download_setting.dart';
import 'package:jhentai/setting/advanced_setting.dart';
import 'package:logger/logger.dart';
import 'package:jhentai/utils/eh_executor.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final previousDatabase = appDb;
  final previousRequest = ehRequest;
  final previousIsolate = isolateService;
  late Directory directory;
  late _DownloadService service;
  late _Request request;
  late _Queue queue;
  late GalleryDownloadInfo info;

  setUpAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    advancedSetting.logLevel.value = Level.off;
    directory = await Directory.systemTemp.createTemp('jhentai-mpv-');
    pathService
      ..tempDir = directory
      ..appDocDir = directory
      ..appSupportDir = directory
      ..systemDownloadDir = directory;
    downloadSetting.downloadPath = directory.path.obs;
  });
  tearDownAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
    await directory.delete(recursive: true);
  });
  setUp(() async {
    appDb = AppDb.forTesting(NativeDatabase.memory());
    await appDb.into(appDb.galleryDownloaded).insert(_gallery);
    request = _Request();
    ehRequest = request;
    isolateService = _PendingMetadata();
    queue = _Queue();
    info = _info();
    service = _DownloadService()
      ..executor = queue
      ..gallerys = [_gallery]
      ..galleryDownloadInfos = {1: info};
    await service.downloadGallery(_gallery, resume: true);
    await queue.next(); // Schedule the two real image parsing tasks.
  });
  tearDown(() async {
    info.speedComputer.dispose();
    await appDb.close();
    appDb = previousDatabase;
    ehRequest = previousRequest;
    isolateService = previousIsolate;
  });

  test('expired in-memory keys refresh once and recover without restarting',
      () async {
    await queue.next(); // Rejected dispatch for page 1.
    expect(info.mpvKey, isNull);
    expect(info.mpvImageKeys, everyElement(isNull));
    expect(info.mpvSkipServerIdentifiers, everyElement(isNull));
    expect(request.removedUrls, contains(_mpvUrl));

    await queue.next(); // Page 2 fetches fresh keys, then dispatches.
    await queue.next(); // Refresh page 1's gallery href.
    queue.tasks.removeAt(0); // Leave the image-byte download outside this test.
    await queue.next(); // Page 1 dispatches with the shared fresh keys.

    expect(request.pageCacheFlags, [false]);
    expect(
        request.dispatches.map((r) => r.mpvKey), ['expired', 'fresh', 'fresh']);
    expect(request.dispatches.map((r) => r.reloadKey),
        ['old-server-1', null, null]);
    expect(info.images.map((image) => image?.url),
        ['https://example.test/1.jpg', 'https://example.test/2.jpg']);
    expect(info.downloadProgress.downloadStatus, DownloadStatus.downloading);
  });

  for (final lateSuccess in [false, true]) {
    test(
        'late ${lateSuccess ? 'success' : 'failure'} cannot overwrite refreshed keys',
        () async {
      final oldPage2 = Completer<Object>();
      request.dispatch = (page, key) async {
        if (key == 'expired' && page == 2) {
          return oldPage2.future;
        }
        return key == 'expired' ? {'error': 'Key expired'} : _image(page);
      };

      final parsePage1 = queue.tasks.removeAt(0);
      final parsePage2 = queue.tasks.removeAt(0);
      final pendingPage2 = parsePage2();
      await parsePage1();
      await queue.next(); // Refresh page 1 href.
      await queue.next(); // Refresh keys and finish page 1.
      expect(info.mpvKey, 'fresh');

      oldPage2.complete(lateSuccess ? _image(2) : {'error': 'Key expired'});
      await pendingPage2;
      expect(info.mpvKey, 'fresh');
      expect(info.mpvImageKeys, ['fresh-1', 'fresh-2']);
      expect(info.mpvSkipServerIdentifiers[1], isNull);

      if (!lateSuccess) {
        queue.tasks.removeAt(0); // Page 1 download.
        await queue.next(); // Page 2 href.
        await queue.next(); // Page 2 dispatch; fresh keys are reused.
        expect(info.images[1]?.url, 'https://example.test/2.jpg');
      }
      expect(request.pageCacheFlags, [false]);
    });
  }

  test(
      'concurrent images share the key refresh even with legacy thumbnail metadata',
      () async {
    info.mpvKey = null;
    info.mpvImageKeys.fillRange(0, 2, null);
    info.imageHrefs = [
      _thumbnail(1, withKey: false),
      _thumbnail(2, withKey: false)
    ];
    final page = Completer<String>();
    request.page = () => page.future;
    final first = queue.tasks.removeAt(0)();
    final second = queue.tasks.removeAt(0)();
    expect(request.pageCacheFlags, [false]);
    page.complete(_freshPage);
    await first;
    await second;
    expect(request.pageCacheFlags, [false]);
    expect(info.images.every((image) => image != null), isTrue);
  });

  test('malformed MPV pages are retried over the network', () async {
    info.mpvKey = null;
    info.mpvImageKeys.fillRange(0, 2, null);
    int attempts = 0;
    request.page = () async =>
        ++attempts == 1 ? '<html>Temporary error</html>' : _freshPage;
    await queue.next();
    expect(request.pageCacheFlags, [false, false]);
    expect(info.images[0]?.url, 'https://example.test/1.jpg');
  });

  test('an obsolete in-flight key fetch cannot restore the rejected session',
      () async {
    info.mpvImageKeys[1] = null;
    final obsoletePage = Completer<String>();
    int fetches = 0;
    request.page =
        () => ++fetches == 1 ? obsoletePage.future : Future.value(_freshPage);
    final parsePage1 = queue.tasks.removeAt(0);
    final parsePage2 = queue.tasks.removeAt(0);
    final pendingPage2 =
        parsePage2(); // Fetches a missing key for the old session.
    await parsePage1(); // Rejects and invalidates that session.
    await queue.next(); // Refresh href.
    await queue.next(); // Fetch new keys and finish page 1.
    obsoletePage.complete(_freshPage.replaceAll('fresh', 'obsolete'));
    await pendingPage2;

    expect(info.mpvKey, 'fresh');
    expect(info.mpvImageKeys, ['fresh-1', 'fresh-2']);
    expect(request.pageCacheFlags, [false, false]);
    expect(
        request.dispatches.map((r) => r.mpvKey), ['expired', 'fresh', 'fresh']);
    expect(info.images.every((image) => image != null), isTrue);
  });

  testWidgets(
      'persistent invalid responses stop after bounded retries and pause only this gallery',
      (tester) async {
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
    await tester.runAsync(() async {
      request.dispatch = (_, __) async => {'error': 'Still invalid'};
      queue.tasks
          .removeAt(1); // Exercise one failing image through all retries.
      int tasksRun = 0;
      while (queue.tasks.isNotEmpty && tasksRun < 10) {
        await queue.next();
        tasksRun++;
      }
      expect(request.dispatches, hasLength(4));
      expect(queue.tasks, isEmpty);
      expect(service.pausedGids, [1]);
      expect(service.pausedAll, isFalse);
      expect(info.mpvKey, isNull,
          reason: 'a manual resume must also fetch fresh keys');
    });
    await tester.pump();
    expect(find.text('parsePageFailed'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    Get.reset();
  });
}

const _mpvUrl = 'https://e-hentai.org/mpv/1/0123456789/';
const _freshPage = '''
<script>
var mpvkey = "fresh";
var imagelist = [{"k":"fresh-1"},{"k":"fresh-2"}];
</script>
''';

Map<String, Object> _image(int page) => {
      'i': 'https://example.test/$page.jpg',
      's': 'server-$page',
      'xres': 100,
      'yres': 200,
    };

GalleryThumbnail _thumbnail(int page, {bool withKey = true}) =>
    GalleryThumbnail(
      href: '$_mpvUrl#page$page',
      isLarge: true,
      thumbUrl: '',
      originImageHash: '0123456789abcdef0123456789abcdef01234567',
      mpvKey: withKey ? '0123456789' : null,
    );

const _gallery = GalleryDownloadedData(
  gid: 1,
  token: '0123456789',
  title: 'Gallery',
  category: 'Manga',
  pageCount: 2,
  galleryUrl: 'https://e-hentai.org/g/1/0123456789/',
  publishTime: '2026-01-01 00:00:00',
  downloadStatusIndex: 1,
  insertTime: '2026-01-01 00:00:00',
  downloadOriginalImage: false,
  priority: 1,
  sortOrder: 0,
  groupName: 'default',
  tags: '',
);

GalleryDownloadInfo _info() => GalleryDownloadInfo(
      thumbnailsCountPerPage: 20,
      tasks: [],
      cancelToken: CancelToken(),
      downloadProgress: GalleryDownloadProgress(
        curCount: 0,
        totalCount: 2,
        downloadStatus: DownloadStatus.downloading,
        hasDownloaded: [false, false],
      ),
      imageHrefs: [_thumbnail(1), _thumbnail(2)],
      images: [null, null],
      preferOriginalImages: [false, false],
      legacyReloadKeyHistory: [{}, {}],
      legacyReloadTriedWithoutKey: [false, false],
      speedComputer: GalleryDownloadSpeedComputer(2, () {}),
      priority: 1,
      sortOrder: 0,
      group: 'default',
      mpvKey: 'expired',
      mpvImageKeys: ['expired-1', 'expired-2'],
      mpvSkipServerIdentifiers: ['old-server-1', 'old-server-2'],
    );

class _Request extends EHRequest {
  final List<bool> pageCacheFlags = [];
  final List<String> removedUrls = [];
  final List<({String mpvKey, String imgKey, String? reloadKey})> dispatches =
      [];
  Future<String> Function() page = () async => _freshPage;
  Future<Object> Function(int page, String key) dispatch = (page, key) async =>
      key == 'expired' ? {'error': 'Key expired'} : _image(page);

  @override
  Future<T> requestMpvPage<T>(String mpvUrl,
      {CancelToken? cancelToken,
      bool useCacheIfAvailable = true,
      required HtmlParser<T> parser}) async {
    pageCacheFlags.add(useCacheIfAvailable);
    return parser(Headers(), await page());
  }

  @override
  Future<T> requestMpvImage<T>({
    required int gid,
    required int page,
    required String imgKey,
    required String mpvKey,
    String? reloadKey,
    CancelToken? cancelToken,
    required HtmlParser<T> parser,
  }) async {
    dispatches.add((mpvKey: mpvKey, imgKey: imgKey, reloadKey: reloadKey));
    return parser(Headers(), await dispatch(page, mpvKey));
  }

  @override
  Future<void> removeCacheByUrl(String url) async => removedUrls.add(url);

  @override
  Future<void> removeCacheByGalleryUrlAndPage(String url, int page) async {}
}

class _DownloadService extends GalleryDownloadService {
  final List<int> pausedGids = [];
  bool pausedAll = false;

  @override
  Future<void> pauseDownloadGallery(GalleryDownloadedData gallery) async {
    pausedGids.add(gallery.gid);
    galleryDownloadInfos[gallery.gid]!.downloadProgress.downloadStatus =
        DownloadStatus.paused;
  }

  @override
  Future<void> pauseAllDownloadGallery() async => pausedAll = true;

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
  }) async =>
          (
            galleryUrl: galleryUrl,
            detailPageInfo: DetailPageInfo(
              imageNoFrom: 0,
              imageNoTo: 1,
              imageCount: 2,
              currentPageNo: 1,
              pageCount: 1,
              thumbnails: [_thumbnail(1), _thumbnail(2)],
            ) as T,
          );
}

class _Queue extends Fake implements EHExecutor {
  final List<AsyncTask> tasks = [];
  Future<void> next() async => await tasks.removeAt(0)();

  @override
  Future<R> scheduleTask<R>(int priority, AsyncTask<R> task) {
    tasks.add(task);
    return Completer<R>().future;
  }
}

// Hold optional metadata writes while exercising the real task pipeline.
class _PendingMetadata extends IsolateService {
  @override
  Future<R> run<Q, R>(IsolateCallback<Q, R> callback, Q message,
          {String? debugLabel}) =>
      Completer<R>().future;
}
