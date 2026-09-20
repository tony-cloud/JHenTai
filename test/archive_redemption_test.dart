import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/downloader/src/model/download_chunk.dart';
import 'package:jhentai/downloader/src/model/download_progress.dart';
import 'package:jhentai/downloader/src/model/proxy_config.dart';
import 'package:jhentai/l18n/locale_text.dart';
import 'package:jhentai/model/archive_unlock_result.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/service/archive_download_service.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/path_service.dart';
import 'package:jhentai/setting/download_setting.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';
import 'package:jhentai/utils/speed_computer.dart';

class _GalleryService extends GalleryDownloadService {
  @override
  void updateArchiveDownloadActivity(bool active) {}
}

class _ArchiveRequests extends EHRequest {
  final List<String> redemptions = [];
  final StreamController<String> unlocked = StreamController.broadcast();
  String? downloadPage;
  int cancellations = 0;

  @override
  ProxyConfig? currentProxyConfig() => null;

  @override
  Future<T> requestUnlockArchive<T>(
      {required String url,
      required bool isOriginal,
      CancelToken? cancelToken,
      HtmlParser<T>? parser}) async {
    redemptions.add(url);
    unlocked.add(url);
    if (downloadPage == null) {
      await cancelToken!.whenCancel;
      throw cancelToken.cancelError!;
    }
    return ArchiveUnlockResult(success: true, msg: '', url: downloadPage) as T;
  }

  @override
  Future<T> requestCancelArchive<T>(
      {required String url, CancelToken? cancelToken, HtmlParser<T>? parser}) async {
    cancellations++;
    return null as T;
  }

  @override
  Future<T> get<T>(
      {required String url,
      Map<String, dynamic>? queryParameters,
      CancelToken? cancelToken,
      Options? options,
      HtmlParser<T>? parser}) async {
    return '/fresh.zip' as T;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ArchiveDownloadService service;
  late _ArchiveRequests requests;
  late AppDb previousDb;
  late EHRequest previousRequest;
  late GalleryDownloadService previousGallery;
  late int previousIsolates;
  late bool previousConcurrency;
  final running = <Future<void>>[];

  setUp(() async {
    HttpOverrides.global = null;
    directory = await Directory.systemTemp.createTemp('archive-redemption-');
    pathService
      ..tempDir = directory
      ..appDocDir = directory
      ..appSupportDir = directory
      ..systemDownloadDir = directory;
    downloadSetting.downloadPath = directory.path.obs;
    previousDb = appDb;
    previousRequest = ehRequest;
    previousGallery = galleryDownloadService;
    previousIsolates = downloadSetting.archiveDownloadIsolateCount.value;
    previousConcurrency = downloadSetting.manageArchiveDownloadConcurrency.value;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    appDb = AppDb.forTesting(NativeDatabase.memory());
    ehRequest = requests = _ArchiveRequests();
    galleryDownloadService = _GalleryService();
    downloadSetting.archiveDownloadIsolateCount.value = 3;
    downloadSetting.manageArchiveDownloadConcurrency.value = true;
    service = ArchiveDownloadService();
  });

  tearDown(() async {
    await service.pauseAllDownloadArchive();
    await Future.wait(running);
    running.clear();
    for (final info in service.archiveDownloadInfos.values) {
      await info.downloadTask?.pause();
      info.speedComputer.dispose();
    }
    await requests.unlocked.close();
    await appDb.close();
    appDb = previousDb;
    ehRequest = previousRequest;
    galleryDownloadService = previousGallery;
    downloadSetting.archiveDownloadIsolateCount.value = previousIsolates;
    downloadSetting.manageArchiveDownloadConcurrency.value = previousConcurrency;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
    await directory.delete(recursive: true);
  });

  Future<ArchiveDownloadedData> addArchive(int gid, {String? url}) async {
    final archive = ArchiveDownloadedData(
      gid: gid,
      token: 'token',
      title: 'archive $gid',
      category: 'Manga',
      pageCount: 1,
      galleryUrl: 'https://example.test/g/$gid/token',
      coverUrl: '',
      size: 32768,
      publishTime: '2026-09-21',
      archiveStatusCode: ArchiveStatus.unlocking.code,
      archivePageUrl: 'https://example.test/archive/$gid',
      downloadUrl: url,
      downloadPageUrl: url == null ? null : 'https://example.test/expired-page',
      isOriginal: true,
      insertTime: '2026-09-21 00:00:0$gid',
      sortOrder: 0,
      groupName: 'default',
      tags: '',
      parseSource: 0,
    );
    await appDb.into(appDb.archiveDownloaded).insert(archive);
    service.archives.add(archive);
    service.archiveDownloadInfos[gid] = ArchiveDownloadInfo(
      size: archive.size,
      parseSource: 0,
      archiveStatus: ArchiveStatus.unlocking,
      downloadUrl: url,
      downloadPageUrl: archive.downloadPageUrl,
      cancelToken: CancelToken(),
      speedComputer: SpeedComputer(),
      sortOrder: 0,
      group: 'default',
    );
    return archive;
  }

  test('queued archives spend no GP and redeem only after a slot is released', () async {
    final archives = <ArchiveDownloadedData>[];
    for (int gid = 1; gid <= 4; gid++) {
      archives.add(await addArchive(gid));
    }
    for (final archive in archives.take(3)) {
      final redeemed = requests.unlocked.stream.first;
      running.add(service.downloadArchive(archive, resume: true));
      await redeemed.timeout(const Duration(seconds: 3));
    }
    await service.downloadArchive(archives.last, resume: true);
    expect(requests.redemptions.length, 3);
    final waiting = service.archiveDownloadInfos[4]!;
    expect(waiting.archiveStatus, ArchiveStatus.waitingIsolate);
    expect(waiting.downloadPageUrl, isNull);
    expect(waiting.downloadUrl, isNull);
    expect(waiting.downloadTask, isNull);

    final nextRedeemed = requests.unlocked.stream.first;
    await service.pauseDownloadArchive(1);
    expect(
        await nextRedeemed.timeout(const Duration(seconds: 3)), archives.last.archivePageUrl);
    expect(requests.redemptions.length, 4);
    expect(waiting.archiveStatus, ArchiveStatus.unlocking);
  });

  test('pausing a queued archive never redeems it when capacity becomes available', () async {
    downloadSetting.archiveDownloadIsolateCount.value = 10;
    final first = await addArchive(1);
    final queued = await addArchive(2);
    final redeemed = requests.unlocked.stream.first;
    running.add(service.downloadArchive(first, resume: true));
    await redeemed.timeout(const Duration(seconds: 3));
    await service.downloadArchive(queued, resume: true);
    await service.pauseDownloadArchive(2);
    await service.pauseDownloadArchive(1);
    await Future.wait(running);
    expect(requests.redemptions, [first.archivePageUrl]);
    expect(service.archiveDownloadInfos[2]!.archiveStatus, ArchiveStatus.paused);
  });

  testWidgets('404 explains renewal and a new URL resumes the existing partial archive',
      (tester) async {
    await tester.pumpWidget(GetMaterialApp(
      translations: LocaleText(),
      locale: const Locale('en', 'US'),
      home: const Scaffold(body: SizedBox()),
    ));
    final payload = Uint8List.fromList(List.generate(32768, (i) => i % 251));
    late HttpServer server;
    late File partialFile;
    late ArchiveDownloadInfo info;
    final ranges = <String>[];
    final releaseResponse = Completer<void>();
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        if (!releaseResponse.isCompleted) {
          releaseResponse.complete();
        }
        await server.close(force: true);
      });
      server.listen((request) async {
        try {
          if (request.uri.path == '/expired.zip') {
            request.response.statusCode = HttpStatus.notFound;
          } else {
            final range = request.headers.value('range')!;
            ranges.add(range);
            request.response.bufferOutput = false;
            request.response.statusCode = HttpStatus.partialContent;
            request.response.contentLength = payload.length - 4096;
            request.response.add(payload.sublist(4096, 8192));
            await request.response.flush();
            await releaseResponse.future;
          }
          await request.response.close();
        } catch (_) {
          await request.response.close().catchError((_) => request.response);
        }
      });
      final baseUrl = 'http://127.0.0.1:${server.port}';
      final archive = await addArchive(1, url: '$baseUrl/expired.zip');
      info = service.archiveDownloadInfos[1]!;
      final savePath = service.computePackingFileDownloadPath(archive);
      final metadata = DownloadProgress(
          url: archive.downloadUrl!,
          savePath: savePath,
          totalBytes: payload.length,
          chunks: [DownloadTrunk(size: payload.length, downloadedBytes: 4096)]).toBuffer;
      final partial = Uint8List(16384 + payload.length)
        ..setRange(0, metadata.length, metadata)
        ..setRange(16384, 16384 + 4096, payload);
      partialFile = File('$savePath.jdtemp');
      await partialFile.parent.create(recursive: true);
      await partialFile.writeAsBytes(partial);
      await service
          .downloadArchive(archive, resume: true)
          .timeout(const Duration(seconds: 10));
      expect(info.archiveStatus, ArchiveStatus.needReUnlock);
      expect(info.downloadTask!.currentBytes, 4096);
      expect(await partialFile.exists(), isTrue);
      requests.downloadPage = '$baseUrl/download-page';
    });
    await tester.pump();
    expect(
        find.textContaining('Archive link expired or is unavailable (404)'), findsOneWidget);

    await tester.runAsync(() async {
      final renewal = service.redeemArchiveAgain(1);
      running.add(renewal);
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (
          (info.downloadTask?.currentBytes ?? 0) < 8192 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(requests.cancellations, 1);
      expect(requests.redemptions.length, 1);
      expect(ranges, ['4096-32767']);
      expect(info.downloadTask!.currentBytes, 8192);
      expect(info.downloadUrl, 'http://127.0.0.1:${server.port}/fresh.zip?start=1');
      final stored = await appDb.select(appDb.archiveDownloaded).getSingle();
      expect(stored.downloadUrl, info.downloadUrl);
      await service.pauseDownloadArchive(1);
      await renewal.timeout(const Duration(seconds: 5));
      releaseResponse.complete();
      expect((await partialFile.readAsBytes()).sublist(16384, 16384 + 8192),
          payload.sublist(0, 8192));
    });
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpWidget(const SizedBox());
    Get.reset();
  });
}
