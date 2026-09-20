import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/downloader/j_downloader.dart';
import 'package:jhentai/downloader/src/util/lock.dart';
import 'package:jhentai/service/archive_download_service.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/path_service.dart';
import 'package:jhentai/setting/download_setting.dart';
import 'package:jhentai/utils/speed_computer.dart';

class _GalleryService extends GalleryDownloadService {
  @override
  void updateArchiveDownloadActivity(bool active) {}
}

class _Task extends JDownloadTask {
  final Future<void> Function() pauseAction;
  _Task(String path, this.pauseAction)
      : super.newTask(
            url: 'https://example.test/archive.zip', savePath: path, isolateCount: 3);
  @override
  Future<void> pause() => pauseAction();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cancel and reparse waits for the old task before forgetting it', () async {
    final directory = await Directory.systemTemp.createTemp('archive-lifecycle-');
    pathService
      ..tempDir = directory
      ..appDocDir = directory
      ..appSupportDir = directory
      ..systemDownloadDir = directory;
    downloadSetting.downloadPath = directory.path.obs;
    final previousDb = appDb;
    final previousGalleryService = galleryDownloadService;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    appDb = AppDb.forTesting(NativeDatabase.memory());
    galleryDownloadService = _GalleryService();
    addTearDown(() async {
      await appDb.close();
      appDb = previousDb;
      galleryDownloadService = previousGalleryService;
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
      await directory.delete(recursive: true);
    });
    const archive = ArchiveDownloadedData(
      gid: 1,
      token: 'token',
      title: 'archive',
      category: 'Manga',
      pageCount: 1,
      galleryUrl: 'https://example.test/g/1/token',
      coverUrl: '',
      size: 1024,
      publishTime: '2026-09-21',
      archiveStatusCode: 60,
      archivePageUrl: '',
      isOriginal: true,
      insertTime: '2026-09-21 00:00:00',
      sortOrder: 0,
      groupName: 'default',
      tags: '',
      parseSource: 1,
    );
    await appDb.into(appDb.archiveDownloaded).insert(archive);
    final info = ArchiveDownloadInfo(
      size: archive.size,
      parseSource: 1,
      archiveStatus: ArchiveStatus.downloading,
      cancelToken: CancelToken(),
      speedComputer: SpeedComputer(updateCallback: () {}),
      sortOrder: 0,
      group: 'default',
      downloadUrl: 'https://example.test/archive.zip',
    );
    final service = ArchiveDownloadService()
      ..archives = [archive]
      ..archiveDownloadInfos = {1: info};
    final oldToken = info.cancelToken;
    final paused = Completer<void>();
    final stop = Completer<void>();
    final task = _Task('${directory.path}/download.zip', () async {
      expect(info.downloadTask, isNotNull);
      paused.complete();
      await stop.future;
    });
    info.downloadTask = task;
    final completion = Completer<void>();
    info.downloadCompleter = completion;
    final cancelledCompletion = expectLater(completion.future, throwsA(anything));
    final cancellation = service.cancelArchive(1);
    await paused.future.timeout(const Duration(seconds: 2));
    expect(info.downloadTask, same(task));
    expect(oldToken.isCancelled, isTrue);
    stop.complete();
    await cancellation;
    await cancelledCompletion;
    expect(info.downloadTask, isNull);
    expect(info.downloadCompleter, isNull);
    expect(info.cancelToken.isCancelled, isFalse);
    info.speedComputer.dispose();
  });

  test('disposing a file queue drains accepted writes even after a failure', () async {
    final lock = Lock();
    final release = Completer<void>();
    final order = <int>[];
    final first = lock.lock(() async {
      await release.future;
      order.add(1);
    });
    final failure = lock.lock<void>(() async {
      order.add(2);
      throw StateError('write failed');
    });
    final failed = expectLater(failure, throwsStateError);
    final last = lock.lock(() async {
      order.add(3);
    });
    final closed = lock.dispose();
    release.complete();
    await Future.wait([first, failed, last, closed]);
    expect(order, [1, 2, 3]);
    await expectLater(lock.lock(() async {}), throwsStateError);
  });
}
