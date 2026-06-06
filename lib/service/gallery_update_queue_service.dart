import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/extension/dio_exception_extension.dart';
import 'package:jhentai/exception/eh_site_exception.dart';
import 'package:jhentai/model/gallery_detail.dart';
import 'package:jhentai/model/gallery_metadata.dart';
import 'package:jhentai/model/gallery_url.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/gallery_history_lineage_service.dart';
import 'package:jhentai/service/history_service.dart';
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

class GalleryUpdateQueueService extends GetxController
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  static const int _galleryMetadataBatchSize = 25;
  static const int _historyMetadataCandidateLimit = 2000;
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
      super.initDependencies..addAll([historyService, _downloadService, wakelockService]);

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
        await _collectMetadataCandidateGalleryUrls(downloadedByGid);

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

    final Map<int, List<GalleryMetadata>> childrenByParentGid =
        _buildChildrenByParentMap(metadatas);
    final Set<int> downloadedGids = downloadedByGid.keys.toSet();
    final Set<int> recentDownloadedGids = _collectRecentDownloadedGids(
      childrenByParentGid: childrenByParentGid,
      downloadedByGid: downloadedByGid,
      downloadedGids: downloadedGids,
    );

    _queue
      ..clear()
      ..addAll(
        recentDownloadedGids.map((gid) => downloadedByGid[gid]).whereType<GalleryDownloadedData>(),
      );

    _summaryTotalCount = _queue.length;
    _setOperationProgress(
      operationLabel: 'updateGallery'.tr,
      processedCount: 0,
      totalCount: _queue.length,
    );

    if (_queue.isEmpty) {
      return;
    }

    while (_queue.isNotEmpty && !_abortRequested) {
      final GalleryDownloadedData oldGallery = _queue.removeFirst();

      _setOperationProgress(
        operationLabel: 'updateGallery'.tr,
        processedCount: _processedCount + 1,
        totalCount: _totalCount,
      );

      if (_downloadService.isUpdatingDependent(oldGallery.gid)) {
        _skippedCount++;
        continue;
      }

      final _QueueUpdateTarget? updateTarget = await _resolveUpdateTargetForQueue(
        oldGallery: oldGallery,
        childrenByParentGid: childrenByParentGid,
        downloadedByGid: downloadedByGid,
        downloadedGids: downloadedGids,
      );

      if (updateTarget == null) {
        _skippedCount++;
        continue;
      }

      if (_downloadService.isUpdatingDependent(updateTarget.downloadedGallery.gid)) {
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
          'Update gallery in queue failed, gid:${updateTarget.downloadedGallery.gid}',
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
      log.error('Update gallery from history failed', e, s);
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

  Future<List<GalleryUrl>> _collectMetadataCandidateGalleryUrls(
    Map<int, GalleryDownloadedData> downloadedByGid,
  ) async {
    final Map<int, GalleryUrl> candidateByGid = <int, GalleryUrl>{};
    final String operationLabel = 'updateGallerySearchingHistory'.tr;
    final histories = await historyService.getLatest10000RawHistory();
    final int totalCount = downloadedByGid.length + histories.length;
    int processedCount = 0;

    _setOperationProgress(
      operationLabel: operationLabel,
      processedCount: processedCount,
      totalCount: totalCount,
    );

    for (final GalleryDownloadedData gallery in downloadedByGid.values) {
      final GalleryUrl? galleryUrl = GalleryUrl.tryParse(gallery.galleryUrl);
      if (galleryUrl != null) {
        candidateByGid[galleryUrl.gid] = galleryUrl;
      }

      processedCount++;
      _notifyOperationProgressPeriodically(
        operationLabel: operationLabel,
        processedCount: processedCount,
        totalCount: totalCount,
        force: processedCount == downloadedByGid.length,
      );
    }
    int count = 0;

    for (int index = 0; index < histories.length; index++) {
      if (_abortRequested) {
        break;
      }

      if (count >= _historyMetadataCandidateLimit) {
        break;
      }

      final history = histories[index];
      processedCount++;

      try {
        final dynamic jsonBody = jsonDecode(history.jsonBody);
        if (jsonBody is! Map) {
          _notifyOperationProgressPeriodically(
            operationLabel: operationLabel,
            processedCount: processedCount,
            totalCount: totalCount,
            force: index + 1 == histories.length,
          );
          continue;
        }

        final String? galleryUrlText = jsonBody['galleryUrl']?.toString();
        if (galleryUrlText == null || galleryUrlText.isEmpty) {
          _notifyOperationProgressPeriodically(
            operationLabel: operationLabel,
            processedCount: processedCount,
            totalCount: totalCount,
            force: index + 1 == histories.length,
          );
          continue;
        }

        final GalleryUrl? galleryUrl = GalleryUrl.tryParse(galleryUrlText);
        if (galleryUrl == null) {
          _notifyOperationProgressPeriodically(
            operationLabel: operationLabel,
            processedCount: processedCount,
            totalCount: totalCount,
            force: index + 1 == histories.length,
          );
          continue;
        }

        if (candidateByGid.containsKey(galleryUrl.gid)) {
          _notifyOperationProgressPeriodically(
            operationLabel: operationLabel,
            processedCount: processedCount,
            totalCount: totalCount,
            force: index + 1 == histories.length,
          );
          continue;
        }

        candidateByGid[galleryUrl.gid] = galleryUrl;
        count++;
      } catch (_) {
        _notifyOperationProgressPeriodically(
          operationLabel: operationLabel,
          processedCount: processedCount,
          totalCount: totalCount,
          force: index + 1 == histories.length,
        );
        continue;
      }

      _notifyOperationProgressPeriodically(
        operationLabel: operationLabel,
        processedCount: processedCount,
        totalCount: totalCount,
        force: index + 1 == histories.length,
      );
    }

    _setOperationProgress(
      operationLabel: operationLabel,
      processedCount: totalCount,
      totalCount: totalCount,
    );

    return candidateByGid.values.toList(growable: false);
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

  Map<int, List<GalleryMetadata>> _buildChildrenByParentMap(
    List<GalleryMetadata> metadatas,
  ) {
    final Map<int, List<GalleryMetadata>> childrenByParentGid = <int, List<GalleryMetadata>>{};

    for (final GalleryMetadata metadata in metadatas) {
      final GalleryUrl? parentGalleryUrl = metadata.parentGalleryUrl;
      if (parentGalleryUrl == null) {
        continue;
      }

      childrenByParentGid
          .putIfAbsent(parentGalleryUrl.gid, () => <GalleryMetadata>[])
          .add(metadata);
    }

    return childrenByParentGid;
  }

  Set<int> _collectRecentDownloadedGids({
    required Map<int, List<GalleryMetadata>> childrenByParentGid,
    required Map<int, GalleryDownloadedData> downloadedByGid,
    required Set<int> downloadedGids,
  }) {
    final Map<int, Set<int>> parentByChildGid = <int, Set<int>>{};
    for (final entry in childrenByParentGid.entries) {
      final int parentGid = entry.key;
      for (final GalleryMetadata child in entry.value) {
        parentByChildGid.putIfAbsent(child.galleryUrl.gid, () => <int>{}).add(parentGid);
      }
    }

    for (final GalleryDownloadedData gallery in downloadedByGid.values) {
      final String? oldVersionGalleryUrlText = gallery.oldVersionGalleryUrl;
      if (oldVersionGalleryUrlText == null || oldVersionGalleryUrlText.isEmpty) {
        continue;
      }

      final GalleryUrl? oldVersionGalleryUrl = GalleryUrl.tryParse(oldVersionGalleryUrlText);
      if (oldVersionGalleryUrl == null || !downloadedGids.contains(oldVersionGalleryUrl.gid)) {
        continue;
      }

      parentByChildGid.putIfAbsent(gallery.gid, () => <int>{}).add(oldVersionGalleryUrl.gid);
    }

    final Set<int> hasDownloadedDescendant = <int>{};

    void markAncestors(int childGid) {
      final Set<int> visited = <int>{};
      final Queue<int> queue = Queue<int>()..add(childGid);

      while (queue.isNotEmpty) {
        final int currentGid = queue.removeFirst();

        if (!visited.add(currentGid)) {
          continue;
        }

        final Set<int> parents = parentByChildGid[currentGid] ?? const <int>{};
        for (final int parentGid in parents) {
          hasDownloadedDescendant.add(parentGid);
          queue.add(parentGid);
        }
      }
    }

    for (final int downloadedGid in downloadedGids) {
      markAncestors(downloadedGid);
    }

    return downloadedGids.where((gid) => !hasDownloadedDescendant.contains(gid)).toSet();
  }

  GalleryMetadata? _resolveLatestNewVersionMetadata({
    required int rootGid,
    required Map<int, List<GalleryMetadata>> childrenByParentGid,
    required Set<int> downloadedGids,
  }) {
    final Set<int> visited = <int>{};
    final List<GalleryMetadata> candidates = <GalleryMetadata>[];

    void search(int currentGid) {
      if (!visited.add(currentGid)) {
        return;
      }

      final List<GalleryMetadata> children =
          childrenByParentGid[currentGid] ?? const <GalleryMetadata>[];

      for (final GalleryMetadata child in children) {
        if (!downloadedGids.contains(child.galleryUrl.gid)) {
          candidates.add(child);
        }
        search(child.galleryUrl.gid);
      }
    }

    search(rootGid);
    return _pickLatestMetadata(candidates);
  }

  GalleryMetadata? _pickLatestMetadata(List<GalleryMetadata> metadatas) {
    if (metadatas.isEmpty) {
      return null;
    }

    metadatas.sort((a, b) {
      final DateTime? aTime = DateTime.tryParse(a.publishTime);
      final DateTime? bTime = DateTime.tryParse(b.publishTime);

      if (aTime != null && bTime != null) {
        final int timeResult = bTime.compareTo(aTime);
        if (timeResult != 0) {
          return timeResult;
        }
      }

      return b.galleryUrl.gid.compareTo(a.galleryUrl.gid);
    });

    return metadatas.first;
  }

  Future<_QueueUpdateTarget?> _resolveUpdateTargetForQueue({
    required GalleryDownloadedData oldGallery,
    required Map<int, List<GalleryMetadata>> childrenByParentGid,
    required Map<int, GalleryDownloadedData> downloadedByGid,
    required Set<int> downloadedGids,
  }) async {
    if (_abortRequested) {
      return null;
    }

    final GalleryMetadata? metadata = _resolveLatestNewVersionMetadata(
      rootGid: oldGallery.gid,
      childrenByParentGid: childrenByParentGid,
      downloadedGids: downloadedGids,
    );

    final GalleryUrl? startUrl = metadata?.galleryUrl ?? GalleryUrl.tryParse(oldGallery.galleryUrl);
    if (startUrl == null) {
      return null;
    }

    if (_abortRequested) {
      return null;
    }

    final GalleryDetail? startDetail = await _fetchGalleryDetailForHistory(
      startUrl,
      useCacheIfAvailable: false,
    );
    if (startDetail == null) {
      return null;
    }

    if (_abortRequested) {
      return null;
    }

    final Set<int> visitedGids = <int>{oldGallery.gid};
    final GalleryDetail? latestDetail = await _resolveLatestGalleryDetail(
      startDetail,
      visitedGids,
    );

    if (latestDetail == null) {
      return null;
    }

    if (latestDetail.galleryUrl.gid == oldGallery.gid) {
      return null;
    }

    if (_downloadService.containGallery(latestDetail.galleryUrl.gid)) {
      return null;
    }

    final GalleryDownloadedData? downloadedGallery = await _resolveLatestDownloadedGalleryInLineage(
      latestDetail: latestDetail,
      downloadedByGid: downloadedByGid,
    );

    if (downloadedGallery == null || downloadedGallery.gid == latestDetail.galleryUrl.gid) {
      return null;
    }

    return (
      downloadedGallery: downloadedGallery,
      latestGalleryUrl: latestDetail.galleryUrl,
    );
  }

  Future<GalleryDownloadedData?> _resolveLatestDownloadedGalleryInLineage({
    required GalleryDetail latestDetail,
    required Map<int, GalleryDownloadedData> downloadedByGid,
  }) async {
    GalleryDetail currentDetail = latestDetail;
    final Set<int> visitedGids = <int>{currentDetail.galleryUrl.gid};

    while (!_abortRequested) {
      final GalleryDownloadedData? downloadedGallery =
          downloadedByGid[currentDetail.galleryUrl.gid];
      if (downloadedGallery != null && _isGalleryDownloaded(downloadedGallery.gid)) {
        return downloadedGallery;
      }

      final GalleryUrl? parentUrl = currentDetail.parentGalleryUrl;
      if (parentUrl == null || !visitedGids.add(parentUrl.gid)) {
        break;
      }

      final GalleryDownloadedData? parentDownloadedGallery = downloadedByGid[parentUrl.gid];
      if (parentDownloadedGallery != null && _isGalleryDownloaded(parentDownloadedGallery.gid)) {
        return parentDownloadedGallery;
      }

      final GalleryDetail? parentDetail = await _fetchGalleryDetailForHistory(
        parentUrl,
        useCacheIfAvailable: false,
      );
      if (parentDetail == null) {
        return null;
      }

      currentDetail = parentDetail;
    }

    return null;
  }

  Future<({GalleryDetail latestDetail, GalleryDownloadedData? downloadedGallery})?>
      _resolveHistoryUpdateTarget(GalleryDetail baseDetail) async {
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
      final ({GalleryDetail galleryDetails, String apikey}) detailPageInfo =
          await ehRequest.requestDetailPage<({GalleryDetail galleryDetails, String apikey})>(
        galleryUrl: galleryUrl.url,
        parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey,
        useCacheIfAvailable: useCacheIfAvailable,
      );
      galleryHistoryLineageService.cacheDetail(detailPageInfo.galleryDetails);
      return detailPageInfo.galleryDetails;
    } on DioException catch (e) {
      log.error('updateGalleryError'.tr, e.errorMsg);
      snack('updateGalleryError'.tr, e.errorMsg ?? '', isShort: true);
    } on EHSiteException catch (e) {
      log.error('updateGalleryError'.tr, e.message);
      snack('updateGalleryError'.tr, e.message, isShort: true);
    } catch (e, s) {
      log.error('updateGalleryError'.tr, e, s);
      snack('updateGalleryError'.tr, e.toString(), isShort: true);
    }

    return null;
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
