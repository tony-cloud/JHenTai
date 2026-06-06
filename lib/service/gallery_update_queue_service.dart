import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/extension/dio_exception_extension.dart';
import 'package:jhentai/exception/eh_site_exception.dart';
import 'package:jhentai/model/gallery_detail.dart';
import 'package:jhentai/model/gallery_history_entry.dart';
import 'package:jhentai/model/gallery_metadata.dart';
import 'package:jhentai/model/gallery_url.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/gallery_history_lineage_service.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/service/wakelock_service.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';
import 'package:jhentai/utils/snack_util.dart';
import 'package:jhentai/utils/toast_util.dart';

GalleryUpdateQueueService galleryUpdateQueueService = GalleryUpdateQueueService();

typedef _GalleryHistoryNode = ({
  GalleryUrl galleryUrl,
  String title,
  String updateTime,
});

typedef _QueueUpdateTarget = ({
  GalleryDownloadedData downloadedGallery,
  GalleryUrl latestGalleryUrl,
});

typedef _MetadataUpdateTarget = ({
  GalleryDownloadedData downloadedGallery,
  GalleryMetadata metadata,
  GalleryUrl latestGalleryUrl,
});

class GalleryUpdateQueueService extends GetxController
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  static const int _galleryMetadataBatchSize = 25;
  static const String _updateQueueLockName = 'gallery_update_queue';

  final GalleryDownloadService _downloadService = galleryDownloadService;
  final ListQueue<GalleryDownloadedData> _queue = ListQueue<GalleryDownloadedData>();

  bool _isHandlingUpdateGallery = false;
  bool _abortRequested = false;

  int _processedCount = 0;
  int _totalCount = 0;
  int _summaryTotalCount = 0;
  int _startedCount = 0;
  int _skippedCount = 0;
  int _failedCount = 0;
  String _operationLabel = '';

  VoidCallback? _stateChangedCallback;

  bool get isHandlingUpdateGallery => _isHandlingUpdateGallery;

  int get processedCount => _processedCount;

  int get totalCount => _totalCount;

  String get operationLabel => _operationLabel.isEmpty ? 'updateGallery'.tr : _operationLabel;

  int get startedCount => _startedCount;

  int get skippedCount => _skippedCount;

  int get failedCount => _failedCount;

  bool get abortRequested => _abortRequested;

  @override
  List<JHLifeCircleBean> get initDependencies =>
      super.initDependencies..addAll([_downloadService, wakelockService]);

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
  }

  @override
  Future<void> doAfterBeanReady() async {}

  bool startOneKeyUpdateQueue(
    List<GalleryDownloadedData> gallerys, {
    VoidCallback? onStateChanged,
  }) {
    if (_isHandlingUpdateGallery) {
      return false;
    }

    _prepareRun(onStateChanged: onStateChanged);

    _queue
      ..clear()
      ..addAll(gallerys);
    _summaryTotalCount = gallerys.length;
    _setOperationProgress(
      operationLabel: 'updateGallerySearchingHistory'.tr,
      processedCount: 0,
      totalCount: gallerys.length,
    );

    unawaited(_runInBackground(_runOneKeyUpdateQueue));
    return true;
  }

  bool startUpdateFromHistory(
    GalleryDetail baseDetail, {
    VoidCallback? onStateChanged,
  }) {
    if (_isHandlingUpdateGallery) {
      return false;
    }

    _prepareRun(onStateChanged: onStateChanged);
    _summaryTotalCount = 1;
    _setOperationProgress(
      operationLabel: 'updateGallerySearchingHistory'.tr,
      processedCount: 0,
      totalCount: 1,
    );

    unawaited(_runInBackground(() => _runHistoryUpdate(baseDetail)));
    return true;
  }

  void requestAbort() {
    if (!_isHandlingUpdateGallery) {
      return;
    }

    _abortRequested = true;
    toast('${'updateGallery'.tr}: ${'stop'.tr}', isCenter: false);
    _notifyStateChanged();
  }

  void _prepareRun({VoidCallback? onStateChanged}) {
    _isHandlingUpdateGallery = true;
    _abortRequested = false;
    _processedCount = 0;
    _totalCount = 0;
    _summaryTotalCount = 0;
    _startedCount = 0;
    _skippedCount = 0;
    _failedCount = 0;
    _operationLabel = 'updateGallery'.tr;
    _stateChangedCallback = onStateChanged;
    _notifyStateChanged();
  }

  Future<void> _runInBackground(Future<void> Function() runLogic) async {
    await wakelockService.acquire(_updateQueueLockName);

    try {
      await runLogic();
    } on DioException catch (_) {
      toast('updateGalleryError'.tr, isCenter: false);
    } on EHSiteException catch (_) {
      toast('updateGalleryError'.tr, isCenter: false);
    } catch (e, s) {
      log.error('Run gallery update queue failed', e, s);
      toast('updateGalleryError'.tr, isCenter: false);
    } finally {
      await wakelockService.release(_updateQueueLockName);

      if (_summaryTotalCount > 0) {
        final String skippedLabel = 'updateGallerySummarySkipped'.tr;
        final String failedLabel = 'updateGallerySummaryFailed'.tr;
        final String summary = _abortRequested
            ? '${'updateGallery'.tr}: ${'stop'.tr} '
                '($_startedCount/$_summaryTotalCount, '
                '$skippedLabel:$_skippedCount, $failedLabel:$_failedCount)'
            : '${'updateGallery'.tr}: '
                '$_startedCount/$_summaryTotalCount, '
                '$skippedLabel:$_skippedCount, $failedLabel:$_failedCount';
        toast(summary, isCenter: false);
      }

      _queue.clear();
      _isHandlingUpdateGallery = false;
      _abortRequested = false;
      _processedCount = 0;
      _totalCount = 0;
      _summaryTotalCount = 0;
      _startedCount = 0;
      _skippedCount = 0;
      _failedCount = 0;
      _operationLabel = 'updateGallery'.tr;
      _notifyStateChanged();
      _stateChangedCallback = null;
    }
  }

  Future<void> _runOneKeyUpdateQueue() async {
    await _downloadService.completed;

    if (_abortRequested) {
      return;
    }

    final Map<int, GalleryDownloadedData> downloadedByGid =
        _collectDownloadedGallerysByGid(_queue.toList(growable: false));

    if (downloadedByGid.isEmpty) {
      toast('updateGalleryHistoryDownloadNotFound'.tr, isCenter: false);
      return;
    }

    toast('updateGallerySearchingHistory'.tr, isCenter: false);

    final List<GalleryUrl> metadataCandidates =
        _collectDownloadedMetadataCandidateGalleryUrls(downloadedByGid);

    if (_abortRequested) {
      return;
    }

    if (metadataCandidates.isEmpty) {
      return;
    }

    final List<GalleryMetadata> metadatas =
        await _requestGalleryMetadatasInBatches(metadataCandidates);

    if (_abortRequested) {
      return;
    }

    if (metadatas.isEmpty) {
      return;
    }

    final List<_QueueUpdateTarget> updateTargets = _resolveApiUpdateTargets(
      metadatas: metadatas,
      downloadedByGid: downloadedByGid,
    );

    _queue.clear();
    _summaryTotalCount = updateTargets.length;
    _setOperationProgress(
      operationLabel: 'updateGallery'.tr,
      processedCount: 0,
      totalCount: updateTargets.length,
    );

    if (updateTargets.isEmpty) {
      return;
    }

    for (final _QueueUpdateTarget updateTarget in updateTargets) {
      if (_abortRequested) {
        break;
      }

      _setOperationProgress(
        operationLabel: 'updateGallery'.tr,
        processedCount: _processedCount + 1,
        totalCount: _totalCount,
      );

      if (_downloadService.isUpdatingDependent(updateTarget.downloadedGallery.gid)) {
        _skippedCount++;
        continue;
      }

      if (_downloadService.containGallery(updateTarget.latestGalleryUrl.gid)) {
        _skippedCount++;
        continue;
      }

      try {
        await _downloadService.updateGallery(
          updateTarget.downloadedGallery,
          updateTarget.latestGalleryUrl,
        );
        _startedCount++;
      } catch (e, s) {
        _failedCount++;
        log.error(
          'Update gallery in queue failed, ${_formatUpdateTargetLogContext(updateTarget)}',
          e,
          s,
        );
      }
    }
  }

  Future<void> _runHistoryUpdate(GalleryDetail baseDetail) async {
    await _downloadService.completed;

    if (_abortRequested) {
      return;
    }

    toast('updateGallerySearchingHistory'.tr, isCenter: false);

    final ({GalleryDetail latestDetail, GalleryDownloadedData? downloadedGallery})? historyResult =
        await _resolveHistoryUpdateTarget(baseDetail);

    if (_abortRequested || historyResult == null) {
      return;
    }

    final GalleryDownloadedData? downloadedGallery = historyResult.downloadedGallery;
    if (downloadedGallery == null) {
      toast('updateGalleryHistoryDownloadNotFound'.tr, isCenter: false);
      _skippedCount = 1;
      _processedCount = 1;
      _notifyStateChanged();
      return;
    }

    final GalleryDetail latestDetail = historyResult.latestDetail;
    if (downloadedGallery.gid == latestDetail.galleryUrl.gid) {
      toast('updateGalleryAlreadyLatest'.tr, isCenter: false);
      _skippedCount = 1;
      _processedCount = 1;
      _notifyStateChanged();
      return;
    }

    if (_downloadService.isUpdatingDependent(downloadedGallery.gid)) {
      _skippedCount = 1;
      _processedCount = 1;
      _notifyStateChanged();
      return;
    }

    try {
      _processedCount = 1;
      _notifyStateChanged();
      await _downloadService.updateGallery(downloadedGallery, latestDetail.galleryUrl);
      _startedCount = 1;
    } catch (e, s) {
      _failedCount = 1;
      log.error(
        'Update gallery from history failed, '
        '${_formatDownloadedUpdateLogContext(downloadedGallery, latestDetail.galleryUrl)}',
        e,
        s,
      );
    }

    _notifyStateChanged();
  }

  Map<int, GalleryDownloadedData> _collectDownloadedGallerysByGid(
    List<GalleryDownloadedData> gallerys,
  ) {
    final Map<int, GalleryDownloadedData> result = <int, GalleryDownloadedData>{};

    for (final GalleryDownloadedData gallery in gallerys) {
      final GalleryDownloadInfo? info = _downloadService.galleryDownloadInfos[gallery.gid];
      if (info?.downloadProgress.downloadStatus != DownloadStatus.downloaded) {
        continue;
      }

      result[gallery.gid] = gallery;
    }

    return result;
  }

  List<GalleryUrl> _collectDownloadedMetadataCandidateGalleryUrls(
    Map<int, GalleryDownloadedData> downloadedByGid,
  ) {
    final List<GalleryUrl> result = <GalleryUrl>[];
    final String operationLabel = 'updateGallerySearchingHistory'.tr;
    int processedCount = 0;

    _setOperationProgress(
      operationLabel: operationLabel,
      processedCount: processedCount,
      totalCount: downloadedByGid.length,
    );

    for (final GalleryDownloadedData gallery in downloadedByGid.values) {
      final GalleryUrl? galleryUrl = GalleryUrl.tryParse(gallery.galleryUrl);
      if (galleryUrl != null) {
        result.add(galleryUrl);
      }

      processedCount++;
      _notifyOperationProgressPeriodically(
        operationLabel: operationLabel,
        processedCount: processedCount,
        totalCount: downloadedByGid.length,
        force: processedCount == downloadedByGid.length,
      );
    }

    return result;
  }

  Future<List<GalleryMetadata>> _requestGalleryMetadatasInBatches(
    List<GalleryUrl> galleryUrls,
  ) async {
    final List<GalleryMetadata> metadatas = <GalleryMetadata>[];

    final List<({int gid, String token})> gidTokenList =
        galleryUrls.map((url) => (gid: url.gid, token: url.token)).toList();
    final String operationLabel = '${'updateGallerySearchingHistory'.tr} (API)';

    _setOperationProgress(
      operationLabel: operationLabel,
      processedCount: 0,
      totalCount: gidTokenList.length,
    );

    for (int index = 0; index < gidTokenList.length; index += _galleryMetadataBatchSize) {
      if (_abortRequested) {
        break;
      }

      final List<({int gid, String token})> batch =
          gidTokenList.skip(index).take(_galleryMetadataBatchSize).toList(
                growable: false,
              );

      metadatas.addAll(await _requestMetadataBatchWithFallback(batch));
      _setOperationProgress(
        operationLabel: operationLabel,
        processedCount: index + batch.length,
        totalCount: gidTokenList.length,
      );
    }

    return metadatas;
  }

  Future<List<GalleryMetadata>> _requestMetadataBatchWithFallback(
    List<({int gid, String token})> batch,
  ) async {
    if (batch.isEmpty) {
      return const <GalleryMetadata>[];
    }

    try {
      return await ehRequest.requestGalleryMetadatas<List<GalleryMetadata>>(
        list: batch,
        parser: EHSpiderParser.galleryMetadataJson2GalleryMetadatas,
      );
    } catch (_) {
      final List<GalleryMetadata> fallbackResult = <GalleryMetadata>[];

      for (final item in batch) {
        if (_abortRequested) {
          break;
        }

        try {
          final GalleryMetadata? metadata =
              await ehRequest.requestGalleryMetadata<GalleryMetadata?>(
            gid: item.gid,
            token: item.token,
            parser: EHSpiderParser.galleryMetadataJson2GalleryMetadata,
          );

          if (metadata != null) {
            fallbackResult.add(metadata);
          }
        } catch (_) {
          continue;
        }
      }

      return fallbackResult;
    }
  }

  List<_QueueUpdateTarget> _resolveApiUpdateTargets({
    required List<GalleryMetadata> metadatas,
    required Map<int, GalleryDownloadedData> downloadedByGid,
  }) {
    final Map<int, _MetadataUpdateTarget> targetByLatestGid = <int, _MetadataUpdateTarget>{};

    for (final GalleryMetadata metadata in metadatas) {
      galleryHistoryLineageService.cacheMetadata(metadata);

      final GalleryDownloadedData? downloadedGallery = downloadedByGid[metadata.galleryUrl.gid];
      if (downloadedGallery == null || !_isGalleryDownloaded(downloadedGallery.gid)) {
        continue;
      }

      final GalleryUrl? latestGalleryUrl = _metadataLatestGalleryUrl(metadata);
      if (latestGalleryUrl == null) {
        continue;
      }

      if (downloadedByGid.containsKey(latestGalleryUrl.gid) ||
          _downloadService.containGallery(latestGalleryUrl.gid)) {
        continue;
      }

      final _MetadataUpdateTarget candidate = (
        downloadedGallery: downloadedGallery,
        metadata: metadata,
        latestGalleryUrl: latestGalleryUrl,
      );
      final _MetadataUpdateTarget? existing = targetByLatestGid[latestGalleryUrl.gid];
      if (existing == null || _isMetadataNewer(metadata, existing.metadata)) {
        targetByLatestGid[latestGalleryUrl.gid] = candidate;
      }
    }

    return targetByLatestGid.values
        .map(
          (_MetadataUpdateTarget target) => (
            downloadedGallery: target.downloadedGallery,
            latestGalleryUrl: target.latestGalleryUrl,
          ),
        )
        .toList(growable: false);
  }

  GalleryUrl? _metadataLatestGalleryUrl(GalleryMetadata metadata) {
    final GalleryUrl? currentGalleryUrl = metadata.currentGalleryUrl;
    if (currentGalleryUrl == null || currentGalleryUrl.gid == metadata.galleryUrl.gid) {
      return null;
    }

    return currentGalleryUrl;
  }

  bool _isMetadataNewer(GalleryMetadata candidate, GalleryMetadata current) {
    final DateTime? candidateTime = DateTime.tryParse(candidate.publishTime);
    final DateTime? currentTime = DateTime.tryParse(current.publishTime);

    if (candidateTime != null && currentTime != null) {
      final int timeResult = candidateTime.compareTo(currentTime);
      if (timeResult != 0) {
        return timeResult > 0;
      }
    } else if (candidateTime != null) {
      return true;
    } else if (currentTime != null) {
      return false;
    }

    return candidate.galleryUrl.gid > current.galleryUrl.gid;
  }

  Future<({GalleryDetail latestDetail, GalleryDownloadedData? downloadedGallery})?>
      _resolveHistoryUpdateTarget(GalleryDetail baseDetail) async {
    final GalleryHistoryChain? historyChain =
        await galleryHistoryLineageService.getHistoryChainFromFirstGallery(
      baseDetail: baseDetail,
      fetchDetail: _fetchGalleryDetailForHistory,
      useCache: false,
    );

    if (historyChain != null) {
      final GalleryDetail? latestDetail = await _resolveLatestDetailFromHistoryChain(
        historyChain,
        baseDetail,
      );
      if (latestDetail == null) {
        return null;
      }

      return (
        latestDetail: latestDetail,
        downloadedGallery: _resolveLatestDownloadedGalleryInHistoryChain(historyChain),
      );
    }

    final Set<int> visitedGids = <int>{baseDetail.galleryUrl.gid};

    final GalleryDetail? latestDetail = await _resolveLatestGalleryDetail(baseDetail, visitedGids);
    if (latestDetail == null) {
      return null;
    }

    GalleryDetail currentDetail = latestDetail;

    while (!_abortRequested) {
      final GalleryDownloadedData? downloadedGallery =
          _downloadService.gallerys.firstWhereOrNull((g) => g.gid == currentDetail.galleryUrl.gid);

      if (downloadedGallery != null) {
        final GalleryDownloadInfo? info =
            _downloadService.galleryDownloadInfos[downloadedGallery.gid];
        if (info?.downloadProgress.downloadStatus == DownloadStatus.downloaded) {
          return (
            latestDetail: latestDetail,
            downloadedGallery: downloadedGallery,
          );
        }
      }

      final GalleryUrl? parentUrl = currentDetail.parentGalleryUrl;
      if (parentUrl == null || visitedGids.contains(parentUrl.gid)) {
        break;
      }

      visitedGids.add(parentUrl.gid);

      final GalleryDetail? parentDetail = await _fetchGalleryDetailForHistory(
        parentUrl,
        useCacheIfAvailable: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (parentDetail == null) {
        return null;
      }

      currentDetail = parentDetail;
    }

    return (latestDetail: latestDetail, downloadedGallery: null);
  }

  Future<GalleryDetail?> _resolveLatestDetailFromHistoryChain(
    GalleryHistoryChain historyChain,
    GalleryDetail baseDetail,
  ) {
    final GalleryUrl latestGalleryUrl = historyChain.latestGalleryUrl;
    if (latestGalleryUrl.gid == baseDetail.galleryUrl.gid) {
      return Future<GalleryDetail?>.value(baseDetail);
    }

    if (latestGalleryUrl.gid == historyChain.firstDetail.galleryUrl.gid) {
      return Future<GalleryDetail?>.value(historyChain.firstDetail);
    }

    return _fetchGalleryDetailForHistory(latestGalleryUrl, useCacheIfAvailable: false);
  }

  GalleryDownloadedData? _resolveLatestDownloadedGalleryInHistoryChain(
    GalleryHistoryChain historyChain,
  ) {
    final int latestIndex = historyChain.indexOfGid(historyChain.latestGalleryUrl.gid);
    final int endIndex = latestIndex == -1 ? historyChain.entries.length - 1 : latestIndex;

    for (int index = endIndex; index >= 0; index--) {
      final GalleryHistoryEntry entry = historyChain.entries[index];
      final GalleryDownloadedData? downloadedGallery = _downloadService.gallerys
          .firstWhereOrNull((gallery) => gallery.gid == entry.galleryUrl.gid);
      if (downloadedGallery != null && _isGalleryDownloaded(downloadedGallery.gid)) {
        return downloadedGallery;
      }
    }

    return null;
  }

  Future<GalleryDetail?> _resolveLatestGalleryDetail(
    GalleryDetail baseDetail,
    Set<int> visitedGids,
  ) async {
    GalleryDetail currentDetail = baseDetail;

    while ((currentDetail.childrenGallerys?.isNotEmpty ?? false) && !_abortRequested) {
      final GalleryUrl? nextUrl = _pickLatestChildGalleryUrl(currentDetail.childrenGallerys);
      if (nextUrl == null) {
        break;
      }

      if (visitedGids.contains(nextUrl.gid)) {
        break;
      }
      visitedGids.add(nextUrl.gid);

      final GalleryDetail? nextDetail = await _fetchGalleryDetailForHistory(
        nextUrl,
        useCacheIfAvailable: false,
      );
      if (nextDetail == null) {
        return null;
      }

      currentDetail = nextDetail;
    }

    return currentDetail;
  }

  GalleryUrl? _pickLatestChildGalleryUrl(List<_GalleryHistoryNode>? childrenGallerys) {
    if (childrenGallerys == null || childrenGallerys.isEmpty) {
      return null;
    }

    _GalleryHistoryNode latest = childrenGallerys.first;
    for (final _GalleryHistoryNode child in childrenGallerys.skip(1)) {
      if (_isHistoryNodeNewer(child, latest)) {
        latest = child;
      }
    }

    return latest.galleryUrl;
  }

  bool _isHistoryNodeNewer(_GalleryHistoryNode candidate, _GalleryHistoryNode current) {
    final DateTime? candidateTime = _parseHistoryNodeTime(candidate.updateTime);
    final DateTime? currentTime = _parseHistoryNodeTime(current.updateTime);

    if (candidateTime != null && currentTime != null) {
      final int timeResult = candidateTime.compareTo(currentTime);
      if (timeResult != 0) {
        return timeResult > 0;
      }
    } else if (candidateTime != null) {
      return true;
    } else if (currentTime != null) {
      return false;
    }

    return candidate.galleryUrl.gid > current.galleryUrl.gid;
  }

  DateTime? _parseHistoryNodeTime(String updateTime) {
    if (updateTime.isEmpty) {
      return null;
    }

    return DateTime.tryParse(updateTime.replaceFirst(' ', 'T'));
  }

  bool _isGalleryDownloaded(int gid) {
    return _downloadService.galleryDownloadInfos[gid]?.downloadProgress.downloadStatus ==
        DownloadStatus.downloaded;
  }

  Future<GalleryDetail?> _fetchGalleryDetailForHistory(
    GalleryUrl galleryUrl, {
    bool useCacheIfAvailable = true,
  }) async {
    final GalleryDetail? cachedDetail = galleryHistoryLineageService.getCachedDetail(galleryUrl);
    if (cachedDetail != null && useCacheIfAvailable) {
      return cachedDetail;
    }

    try {
      final ({GalleryDetail galleryDetails, String apikey}) detailPageInfo = (await _downloadService
              .requestGalleryDetailWithExFallback<({GalleryDetail galleryDetails, String apikey})>(
        galleryUrl: galleryUrl,
        parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey,
        useCacheIfAvailable: useCacheIfAvailable,
        logContext: 'Update history gallery detail',
      ))
          .detailPageInfo;
      galleryHistoryLineageService.cacheDetail(detailPageInfo.galleryDetails);
      return detailPageInfo.galleryDetails;
    } on DioException catch (e) {
      log.error(
        '${'updateGalleryError'.tr}, ${_formatGalleryUrlLogContext(galleryUrl)}',
        e.errorMsg,
      );
      snack('updateGalleryError'.tr, e.errorMsg ?? '', isShort: true);
    } on EHSiteException catch (e) {
      log.error(
        '${'updateGalleryError'.tr}, ${_formatGalleryUrlLogContext(galleryUrl)}',
        e.message,
      );
      snack('updateGalleryError'.tr, e.message, isShort: true);
    } catch (e, s) {
      log.error(
        '${'updateGalleryError'.tr}, ${_formatGalleryUrlLogContext(galleryUrl)}',
        e,
        s,
      );
      snack('updateGalleryError'.tr, e.toString(), isShort: true);
    }

    return null;
  }

  String _formatUpdateTargetLogContext(_QueueUpdateTarget target) {
    return _formatDownloadedUpdateLogContext(
      target.downloadedGallery,
      target.latestGalleryUrl,
    );
  }

  String _formatDownloadedUpdateLogContext(
    GalleryDownloadedData downloadedGallery,
    GalleryUrl targetGalleryUrl,
  ) {
    return 'downloaded gid:${downloadedGallery.gid}, '
        'downloaded url:${downloadedGallery.galleryUrl}, '
        'target gid:${targetGalleryUrl.gid}, '
        'target url:${targetGalleryUrl.url}';
  }

  String _formatGalleryUrlLogContext(GalleryUrl galleryUrl) {
    return 'gid:${galleryUrl.gid}, url:${galleryUrl.url}';
  }

  void _notifyStateChanged() {
    _stateChangedCallback?.call();
    update();
  }

  void _setOperationProgress({
    required String operationLabel,
    required int processedCount,
    required int totalCount,
  }) {
    _operationLabel = operationLabel;
    _totalCount = totalCount < 0 ? 0 : totalCount;
    _processedCount = processedCount.clamp(0, _totalCount);
    _notifyStateChanged();
  }

  void _notifyOperationProgressPeriodically({
    required String operationLabel,
    required int processedCount,
    required int totalCount,
    bool force = false,
  }) {
    if (!force && processedCount % _galleryMetadataBatchSize != 0) {
      return;
    }

    _setOperationProgress(
      operationLabel: operationLabel,
      processedCount: processedCount,
      totalCount: totalCount,
    );
  }
}
