import 'dart:async';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/exception/eh_site_exception.dart';
import 'package:jhentai/extension/dio_exception_extension.dart';
import 'package:jhentai/model/gallery.dart';
import 'package:jhentai/model/gallery_archive.dart';
import 'package:jhentai/model/gallery_detail.dart';
import 'package:jhentai/model/gallery_page.dart';
import 'package:jhentai/model/search_config.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/pages/base/multi_select/multi_select_batch_download_util.dart';
import 'package:jhentai/service/archive_download_service.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/gallery_update_queue_service.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/setting/user_setting.dart';
import 'package:jhentai/utils/convert_util.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';

GalleryBatchDownloadService galleryBatchDownloadService = GalleryBatchDownloadService();

class GalleryBatchDownloadSummary {
  const GalleryBatchDownloadSummary({
    required this.queuedDownloadCount,
    required this.updateQueuedCount,
    required this.failedCount,
    required this.aborted,
  });

  final int queuedDownloadCount;
  final int updateQueuedCount;
  final int failedCount;
  final bool aborted;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'queuedDownloadCount': queuedDownloadCount,
      'updateQueuedCount': updateQueuedCount,
      'failedCount': failedCount,
      'aborted': aborted,
    };
  }
}

class GalleryBatchDownloadService extends GetxController
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  bool _isRunning = false;
  bool _abortRequested = false;
  String _phase = 'idle';
  int _totalCount = 0;
  int _processedCount = 0;
  DateTime? _lastUpdatedAt;

  bool get isRunning => _isRunning;

  @override
  List<JHLifeCircleBean> get initDependencies => super.initDependencies
    ..addAll(<JHLifeCircleBean>[
      galleryDownloadService,
      archiveDownloadService,
      galleryUpdateQueueService,
      userSetting,
    ]);

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
  }

  @override
  Future<void> doAfterBeanReady() async {}

  Map<String, dynamic> getStatusPayload() {
    return <String, dynamic>{
      'running': _isRunning,
      'abortRequested': _abortRequested,
      'phase': _phase,
      'totalCount': _totalCount,
      'processedCount': _processedCount,
      'updatedAt': _lastUpdatedAt?.toIso8601String(),
    };
  }

  void requestAbort() {
    if (!_isRunning) {
      return;
    }

    _abortRequested = true;
    _touchStatus();
  }

  Future<GalleryBatchDownloadSummary> startForSelectedGalleries({
    required List<Gallery> targetGallerys,
    required String group,
    required bool downloadOriginalImage,
    required bool useArchiveForNewGalleryOnly,
  }) {
    return _runBatchDownloadAndUpdate(
      targetGallerys: targetGallerys,
      group: group,
      downloadOriginalImage: downloadOriginalImage,
      useArchiveForNewGalleryOnly: useArchiveForNewGalleryOnly,
    );
  }

  Future<GalleryBatchDownloadSummary> startForFavoriteSearchConfig({
    required SearchConfig searchConfig,
    required String group,
    required bool downloadOriginalImage,
    required bool useArchiveForNewGalleryOnly,
  }) async {
    _ensureIdle();
    _beginRun(phase: 'collecting');

    try {
      final List<Gallery> gallerys = await _collectGallerysBySearchConfig(searchConfig);

      if (_abortRequested) {
        return const GalleryBatchDownloadSummary(
          queuedDownloadCount: 0,
          updateQueuedCount: 0,
          failedCount: 0,
          aborted: true,
        );
      }

      _phase = 'queueing';
      _touchStatus();

      return _runBatchDownloadAndUpdate(
        targetGallerys: gallerys,
        group: group,
        downloadOriginalImage: downloadOriginalImage,
        useArchiveForNewGalleryOnly: useArchiveForNewGalleryOnly,
        skipIdleGuard: true,
      );
    } finally {
      _finishRun();
    }
  }

  Future<GalleryBatchDownloadSummary> _runBatchDownloadAndUpdate({
    required List<Gallery> targetGallerys,
    required String group,
    required bool downloadOriginalImage,
    required bool useArchiveForNewGalleryOnly,
    bool skipIdleGuard = false,
  }) async {
    if (!skipIdleGuard) {
      _ensureIdle();
      _beginRun(phase: 'queueing');
    }

    try {
      if (targetGallerys.isEmpty || _abortRequested) {
        return GalleryBatchDownloadSummary(
          queuedDownloadCount: 0,
          updateQueuedCount: 0,
          failedCount: 0,
          aborted: _abortRequested,
        );
      }

      await galleryDownloadService.completed;
      await archiveDownloadService.completed;

      _totalCount = targetGallerys.length;
      _processedCount = 0;
      _touchStatus();

      final Map<int, GalleryDownloadedData> downloadedGallerysByGid = <int, GalleryDownloadedData>{
        for (final GalleryDownloadedData gallery in galleryDownloadService.gallerys)
          gallery.gid: gallery,
      };
      final Set<int> archiveGids =
          archiveDownloadService.archives.map((archive) => archive.gid).toSet();
      final Set<int> handledGids = <int>{};
      final List<GalleryDownloadedData> updateCandidates = <GalleryDownloadedData>[];

      int queuedDownloadCount = 0;
      int failedCount = 0;

      for (int index = 0; index < targetGallerys.length; index++) {
        if (_abortRequested) {
          break;
        }

        final Gallery gallery = targetGallerys[index];
        _processedCount = index + 1;
        _touchStatus();

        if (!handledGids.add(gallery.gid)) {
          continue;
        }

        final GalleryDownloadedData? downloadedGallery = downloadedGallerysByGid[gallery.gid];
        final DownloadStatus? downloadStatus = downloadedGallery == null
            ? null
            : galleryDownloadService
                .galleryDownloadInfos[gallery.gid]?.downloadProgress.downloadStatus;

        switch (decideBatchGalleryDownloadAction(
          hasGalleryRecord: downloadedGallery != null,
          galleryStatus: downloadStatus,
          hasArchiveRecord: archiveGids.contains(gallery.gid),
        )) {
          case BatchGalleryDownloadAction.update:
            updateCandidates.add(downloadedGallery!);
            break;
          case BatchGalleryDownloadAction.download:
            final bool queued = await _queueNewGalleryDownload(
              gallery,
              group: group,
              downloadOriginalImage: downloadOriginalImage,
              useArchiveForNewGalleryOnly: useArchiveForNewGalleryOnly,
            );

            if (queued) {
              queuedDownloadCount++;
            } else {
              failedCount++;
            }
            break;
          case BatchGalleryDownloadAction.skip:
            break;
        }

        if ((index + 1) % 5 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      int updateQueuedCount = 0;

      if (!_abortRequested && updateCandidates.isNotEmpty) {
        final bool started = galleryUpdateQueueService.startOneKeyUpdateQueue(
          updateCandidates,
        );

        if (started) {
          updateQueuedCount = updateCandidates.length;
        } else {
          failedCount += updateCandidates.length;
        }
      }

      return GalleryBatchDownloadSummary(
        queuedDownloadCount: queuedDownloadCount,
        updateQueuedCount: updateQueuedCount,
        failedCount: failedCount,
        aborted: _abortRequested,
      );
    } finally {
      if (!skipIdleGuard) {
        _finishRun();
      }
    }
  }

  Future<List<Gallery>> _collectGallerysBySearchConfig(
    SearchConfig searchConfig,
  ) async {
    final SearchConfig copiedSearchConfig = SearchConfig.fromJson(searchConfig.toJson());
    final List<Gallery> gallerys = <Gallery>[];
    final Set<int> handledGids = <int>{};
    String? nextGid;

    while (!_abortRequested) {
      final GalleryPageInfo pageInfo = await ehRequest.requestGalleryPage(
        nextGid: nextGid,
        searchConfig: copiedSearchConfig,
        parser: EHSpiderParser.galleryPage2GalleryPageInfo,
      );

      for (final Gallery gallery in pageInfo.gallerys) {
        if (handledGids.add(gallery.gid)) {
          gallerys.add(gallery);
        }
      }

      if (pageInfo.nextGid == null) {
        return gallerys;
      }

      nextGid = pageInfo.nextGid;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    return gallerys;
  }

  Future<bool> _queueNewGalleryDownload(
    Gallery gallery, {
    required String group,
    required bool downloadOriginalImage,
    required bool useArchiveForNewGalleryOnly,
  }) async {
    if (useArchiveForNewGalleryOnly) {
      final ArchiveDownloadedData? archiveData =
          await _prepareArchiveDownloadData(gallery, group: group);

      if (archiveData != null) {
        if (!archiveDownloadService.containArchive(archiveData.gid)) {
          unawaited(archiveDownloadService.downloadArchive(archiveData));
          return true;
        }

        return false;
      }
    }

    final GalleryDownloadedData? downloadData = await _prepareDownloadData(
      gallery,
      group: group,
      downloadOriginalImage: downloadOriginalImage,
    );

    if (downloadData == null) {
      return false;
    }

    if (galleryDownloadService.containGallery(downloadData.gid)) {
      return false;
    }

    await galleryDownloadService.downloadGallery(downloadData);
    return true;
  }

  Future<GalleryDownloadedData?> _prepareDownloadData(
    Gallery gallery, {
    required String group,
    required bool downloadOriginalImage,
  }) async {
    GalleryDetail? detail;

    if (gallery.pageCount == null ||
        gallery.uploader == null ||
        gallery.publishTime.isEmpty ||
        gallery.tags.isEmpty) {
      try {
        final ({GalleryDetail galleryDetails, String apikey}) detailResult =
            await ehRequest.requestDetailPage(
          galleryUrl: gallery.galleryUrl.url,
          parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey,
        );
        detail = detailResult.galleryDetails;
      } on DioException catch (e) {
        log.error('getGalleryDetailFailed', e.errorMsg);
        return null;
      } on EHSiteException catch (e) {
        log.error('getGalleryDetailFailed', e.message);
        return null;
      }
    }

    final GalleryDetail? galleryDetail = detail;
    final int pageCount = galleryDetail?.pageCount ?? gallery.pageCount ?? 0;
    if (pageCount <= 0) {
      log.warning('Skip download because pageCount missing. gid: ${gallery.gid}');
      return null;
    }

    final String title = galleryDetail?.japaneseTitle ?? galleryDetail?.rawTitle ?? gallery.title;
    final DateTime now = DateTime.now();

    return GalleryDownloadedData(
      gid: galleryDetail?.galleryUrl.gid ?? gallery.gid,
      token: galleryDetail?.galleryUrl.token ?? gallery.token,
      title: title,
      category: galleryDetail?.category ?? gallery.category,
      pageCount: pageCount,
      galleryUrl: galleryDetail?.galleryUrl.url ?? gallery.galleryUrl.url,
      uploader: galleryDetail?.uploader ?? gallery.uploader,
      publishTime: galleryDetail?.publishTime ?? gallery.publishTime,
      downloadStatusIndex: DownloadStatus.downloading.index,
      downloadOriginalImage: downloadOriginalImage,
      sortOrder: 0,
      groupName: group,
      insertTime: now.toString(),
      priority: GalleryDownloadService.defaultDownloadGalleryPriority,
      tags: tagMap2TagString(galleryDetail?.tags ?? gallery.tags),
      tagRefreshTime: now.toString(),
    );
  }

  Future<ArchiveDownloadedData?> _prepareArchiveDownloadData(
    Gallery gallery, {
    required String group,
  }) async {
    if (!userSetting.hasLoggedIn()) {
      return null;
    }

    try {
      final ({GalleryDetail galleryDetails, String apikey}) detailResult =
          await ehRequest.requestDetailPage(
        galleryUrl: gallery.galleryUrl.url,
        parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey,
      );
      final GalleryDetail detail = detailResult.galleryDetails;
      final GalleryArchive archive = await ehRequest.get(
        url: detail.archivePageUrl,
        parser: EHSpiderParser.archivePage2Archive,
      );

      if (archive.originalSize.isEmpty) {
        return null;
      }

      final DateTime now = DateTime.now();

      return ArchiveDownloadedData(
        gid: detail.galleryUrl.gid,
        token: detail.galleryUrl.token,
        title: detail.japaneseTitle ?? detail.rawTitle,
        category: detail.category,
        pageCount: detail.pageCount,
        galleryUrl: detail.galleryUrl.url,
        uploader: detail.uploader,
        size: _computeArchiveSizeInBytes(archive.originalSize),
        coverUrl: detail.cover.url,
        publishTime: detail.publishTime,
        archiveStatusCode: ArchiveStatus.unlocking.code,
        archivePageUrl: detail.archivePageUrl,
        isOriginal: true,
        insertTime: now.toString(),
        sortOrder: 0,
        groupName: group,
        tags: tagMap2TagString(detail.tags),
        tagRefreshTime: now.toString(),
        parseSource: ArchiveParseSource.official.code,
      );
    } on DioException catch (e) {
      log.error('getGalleryArchiveFailed', e.errorMsg);
      return null;
    } on EHSiteException catch (e) {
      log.error('getGalleryArchiveFailed', e.message);
      return null;
    } catch (e, s) {
      log.error('getGalleryArchiveFailed', e, s);
      return null;
    }
  }

  int _computeArchiveSizeInBytes(String sizeString) {
    final List<String> parts = sizeString.split(' ');
    final double number = double.parse(parts[0]);
    final String unit = parts[1];

    if (unit.startsWith('K')) {
      return (number * 1024).toInt();
    }
    if (unit.startsWith('M')) {
      return (number * 1024 * 1024).toInt();
    }

    return (number * 1024 * 1024 * 1024).toInt();
  }

  void _ensureIdle() {
    if (_isRunning) {
      throw StateError('batch download and update is already running');
    }
  }

  void _beginRun({required String phase}) {
    _isRunning = true;
    _abortRequested = false;
    _phase = phase;
    _totalCount = 0;
    _processedCount = 0;
    _touchStatus();
  }

  void _finishRun() {
    _isRunning = false;
    _abortRequested = false;
    _phase = 'idle';
    _totalCount = 0;
    _processedCount = 0;
    _touchStatus();
  }

  void _touchStatus() {
    _lastUpdatedAt = DateTime.now();
  }
}
