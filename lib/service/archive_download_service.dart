import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_instance/get_instance.dart';
import 'package:get/get_rx/get_rx.dart';
import 'package:get/get_state_manager/src/simple/get_controllers.dart';
import 'package:get/get_utils/get_utils.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/downloader/j_downloader.dart';
import 'package:jhentai/downloader/src/download/content_length_retry_policy.dart';
import 'package:jhentai/database/dao/archive_group_dao.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/exception/eh_site_exception.dart';
import 'package:jhentai/model/archive_bot_response/archive_bot_response.dart';
import 'package:jhentai/model/archive_bot_response/archive_resolve_vo.dart';
import 'package:jhentai/model/archive_unlock_result.dart';
import 'package:jhentai/network/archive_bot_request.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/service/isolate_service.dart';
import 'package:jhentai/service/super_resolution_service.dart';
import 'package:jhentai/setting/archive_bot_setting.dart';
import 'package:jhentai/setting/download_setting.dart';
import 'package:jhentai/setting/network_setting.dart';
import 'package:jhentai/service/path_service.dart';
import 'package:jhentai/service/doh_service.dart';
import 'package:jhentai/utils/archive_bot_response_parser.dart';
import 'package:jhentai/utils/speed_computer.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart';
import 'package:retry/retry.dart';

import 'package:jhentai/consts/locale_consts.dart';
import 'package:jhentai/database/dao/archive_dao.dart';
import 'package:jhentai/exception/cancel_exception.dart';
import 'package:jhentai/model/comic_info.dart';
import 'package:jhentai/model/gallery_detail.dart';
import 'package:jhentai/model/gallery_image.dart';
import 'package:jhentai/model/gallery_metadata.dart';
import 'package:jhentai/pages/download/grid/mixin/grid_download_page_service_mixin.dart';
import 'package:jhentai/setting/advanced_setting.dart';
import 'package:jhentai/utils/archive_util.dart';
import 'package:jhentai/utils/convert_util.dart';
import 'package:jhentai/utils/file_util.dart';
import 'package:jhentai/utils/snack_util.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/service/wakelock_service.dart';
import 'package:jhentai/consts/rpc_consts.dart';
import 'package:jhentai/network/rpc_request.dart';
import 'package:jhentai/service/rpc_service.dart';
import 'package:jhentai/setting/rpc_setting.dart';

ArchiveDownloadService archiveDownloadService = ArchiveDownloadService();

typedef ArchiveMitigationReport = ({
  int checked,
  int migrated,
  int replaced,
  int keptOriginal,
  int skipped,
  int failed,
});

class ArchiveDownloadService extends GetxController
    with GridBasePageServiceMixin, JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  static const String archiveStatusId = 'archiveStatusId';
  static const String archiveSpeedComputerId = 'archiveSpeedComputerId';

  static const int _maxRetryTimes = 3;
  static const String metadataFileName = 'ametadata';
  static const int _maxTitleLength = 80;
  static const int _maxIsolateCountsTotal = 10;
  static const String _mitigationLockName = 'archive_mitigation';
  static const int _mitigationHashBatchSize = 16;
  static const int _mitigationHashConcurrency = 4;

  final Completer<bool> _completer = Completer();

  Future<bool> get completed => _completer.future;

  List<String> allGroups = [];
  List<ArchiveDownloadedData> archives = <ArchiveDownloadedData>[];
  Map<int, ArchiveDownloadInfo> archiveDownloadInfos = {};

  final Map<int, Completer<void>> _archiveRuns = {};
  final Map<int, int> _archiveSlots = {};
  final Set<int> _renewingArchives = {};

  final Queue<int> _mitigationQueue = Queue<int>();
  final Set<int> _queuedMitigationGids = <int>{};
  final Set<int> _runningMitigationGids = <int>{};
  final Map<int, Completer<ArchiveMitigationReport>> _mitigationCompleters =
      <int, Completer<ArchiveMitigationReport>>{};
  CancelToken _mitigationCancelToken = CancelToken();
  int _mitigationSessionId = 0;
  bool _mitigationWorkerRunning = false;

  List<ArchiveDownloadedData> archivesWithGroup(String group) =>
      archives.where((g) => archiveDownloadInfos[g.gid]!.group == group).toList();

  late Worker isolateCountListener;
  late Worker proxyConfigListener;
  late Worker timeoutListener;
  late Worker concurrencyManagementListener;

  Timer? _remoteRefreshTimer;
  bool _remoteRefreshInFlight = false;
  bool _remoteRpcDataActive = false;

  bool get _shouldUseRemoteArchiveRpcData {
    if (rpcSetting.enableRpcMode.isFalse) {
      return false;
    }
    if (rpcService.capabilities.isEmpty) {
      return true;
    }
    return rpcService.supportsCapability(RPCCapabilities.downloadArchiveList);
  }

  bool get usesRemoteRpcData => _remoteRpcDataActive;

  bool _isArchiveStatusActive(ArchiveStatus status) {
    return status.code >= ArchiveStatus.unlocking.code &&
        status.code < ArchiveStatus.completed.code;
  }

  bool _hasActiveArchiveDownloads() {
    return archiveDownloadInfos.values.any(
      (info) => _isArchiveStatusActive(info.archiveStatus),
    );
  }

  void _notifyDownloadActivityChanged() {
    galleryDownloadService.updateArchiveDownloadActivity(_hasActiveArchiveDownloads());
  }

  @override
  List<JHLifeCircleBean> get initDependencies => super.initDependencies
    ..addAll([isolateService, wakelockService, rpcSetting, rpcService, rpcRequest]);

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);

    if (GetPlatform.isWeb) {
      _completer.complete(true);
      return;
    }

    if (_shouldUseRemoteArchiveRpcData) {
      bool initializedRemote = await refreshRemoteArchives();
      if (initializedRemote) {
        _startRemoteRefreshTimerIfNeeded();
        _completer.complete(true);
        return;
      }
      log.warning('RPC archive source is unavailable, fallback to local data.');
    }

    _remoteRpcDataActive = false;

    await _instantiateFromDB();

    log.debug('Archive download tasks count: ${archives.length}');

    for (ArchiveDownloadedData archive in archives) {
      if (archive.archiveStatusCode >= ArchiveStatus.unlocking.code &&
          archive.archiveStatusCode <= ArchiveStatus.unpacking.code) {
        downloadArchive(archive, resume: true);
      }
    }

    _completer.complete(true);

    isolateCountListener = ever(
      downloadSetting.archiveDownloadIsolateCount,
      (_) => _onIsolateCountChange(),
    );
    concurrencyManagementListener = ever(
      downloadSetting.manageArchiveDownloadConcurrency,
      (_) => _tryWakeWaitingTasks(),
    );
    proxyConfigListener = everAll([
      networkSetting.proxyAddress,
      networkSetting.proxyUsername,
      networkSetting.proxyPassword,
    ], (_) => _onProxyConfigChange());
    timeoutListener = everAll([
      networkSetting.connectTimeout,
      networkSetting.receiveTimeout,
    ], (_) => _onTimeoutChange());

    if (downloadSetting.restoreTasksAutomatically.isTrue) {
      await restoreTasks();
    }
  }

  @override
  Future<void> doAfterBeanReady() async {
    if (usesRemoteRpcData) {
      await refreshRemoteArchives();
      _startRemoteRefreshTimerIfNeeded();
    }
  }

  @override
  void onClose() {
    super.dispose();

    _remoteRefreshTimer?.cancel();
    isolateCountListener.dispose();
    proxyConfigListener.dispose();
    timeoutListener.dispose();
    concurrencyManagementListener.dispose();

    for (final Completer<ArchiveMitigationReport> completer in _mitigationCompleters.values) {
      if (!completer.isCompleted) {
        completer.complete(_failedMitigationReport(0));
      }
    }

    _mitigationCancelToken.cancel('Archive mitigation service disposed');
    _mitigationQueue.clear();
    _queuedMitigationGids.clear();
    _runningMitigationGids.clear();
    _mitigationCompleters.clear();
    unawaited(wakelockService.release(_mitigationLockName));
  }

  // --------------- Remote RPC thin-client helpers ---------------

  Future<void> manualRefreshRemoteStatus() async {
    if (!_shouldUseRemoteArchiveRpcData) {
      return;
    }
    await _refreshRemoteArchiveSnapshotSafely();
  }

  void _startRemoteRefreshTimerIfNeeded() {
    _remoteRefreshTimer?.cancel();
    _remoteRefreshTimer = null;

    if (!usesRemoteRpcData) {
      return;
    }
    if (rpcSetting.autoRefreshRemoteDownloads.isFalse) {
      return;
    }

    final Duration interval = Duration(
      seconds: rpcSetting.remoteDownloadRefreshIntervalSeconds.value,
    );
    _remoteRefreshTimer = Timer.periodic(interval, (_) {
      unawaited(_refreshRemoteArchiveSnapshotSafely());
    });
  }

  Future<void> _refreshRemoteArchiveSnapshotSafely() async {
    if (_remoteRefreshInFlight) {
      return;
    }
    _remoteRefreshInFlight = true;
    try {
      await refreshRemoteArchives();
    } finally {
      _remoteRefreshInFlight = false;
    }
  }

  Future<bool> refreshRemoteArchives() async {
    if (!_shouldUseRemoteArchiveRpcData) {
      _remoteRpcDataActive = false;
      _clearRemoteArchiveInfos();
      return false;
    }

    try {
      final Map<String, dynamic> result = await rpcRequest.requestDownloadArchiveList();
      _applyRemoteArchiveSnapshot(result);
      _remoteRpcDataActive = true;
      _startRemoteRefreshTimerIfNeeded();
      return true;
    } catch (e, stack) {
      _remoteRpcDataActive = false;
      _remoteRefreshTimer?.cancel();
      _remoteRefreshTimer = null;
      log.error('Failed to refresh remote archive list', e, stack);
      return false;
    }
  }

  void _clearRemoteArchiveInfos() {
    for (final ArchiveDownloadInfo info in archiveDownloadInfos.values) {
      info.speedComputer.dispose();
    }
    allGroups = <String>[];
    archives = <ArchiveDownloadedData>[];
    archiveDownloadInfos = <int, ArchiveDownloadInfo>{};
    update([archiveStatusId]);
  }

  void _applyRemoteArchiveSnapshot(Map<String, dynamic> payload) {
    final List<ArchiveDownloadedData> remoteArchives =
        ((payload['archives'] as List?) ?? const <dynamic>[])
            .whereType<Map>()
            .map((map) => ArchiveDownloadedData.fromJson(map.cast<String, dynamic>()))
            .toList(growable: false);

    final Map<int, Map<String, dynamic>> infoByGid = <int, Map<String, dynamic>>{};
    for (final dynamic rawInfo in (payload['infos'] as List?) ?? const <dynamic>[]) {
      if (rawInfo is Map) {
        final Map<String, dynamic> casted = rawInfo.cast<String, dynamic>();
        infoByGid[casted['gid'] as int] = casted;
      }
    }

    for (final ArchiveDownloadInfo info in archiveDownloadInfos.values) {
      info.speedComputer.dispose();
    }

    archives = remoteArchives;
    allGroups = ((payload['groups'] as List?) ?? const <dynamic>[])
        .map((group) => group.toString())
        .toList(growable: false);
    if (allGroups.isEmpty) {
      allGroups = remoteArchives
          .map((a) => infoByGid[a.gid]?['group']?.toString() ?? 'default')
          .toSet()
          .toList(growable: false);
    }

    archiveDownloadInfos = <int, ArchiveDownloadInfo>{
      for (final ArchiveDownloadedData archive in remoteArchives)
        archive.gid: _buildRemoteArchiveDownloadInfo(archive, infoByGid[archive.gid]),
    };

    update([archiveStatusId]);
  }

  ArchiveDownloadInfo _buildRemoteArchiveDownloadInfo(
    ArchiveDownloadedData archive,
    Map<String, dynamic>? rawInfo,
  ) {
    return ArchiveDownloadInfo(
      size: rawInfo?['size'] is int ? rawInfo!['size'] as int : 0,
      parseSource: rawInfo?['parseSource'] is int
          ? rawInfo!['parseSource'] as int
          : archive.parseSource,
      archiveStatus: ArchiveStatus.fromCode(
        rawInfo?['archiveStatusCode'] is int
            ? rawInfo!['archiveStatusCode'] as int
            : archive.archiveStatusCode,
      ),
      cancelToken: CancelToken(),
      speedComputer: SpeedComputer(
        updateCallback: () => update(['$archiveSpeedComputerId::${archive.gid}']),
      ),
      sortOrder: rawInfo?['sortOrder'] is int ? rawInfo!['sortOrder'] as int : 0,
      group: rawInfo?['group']?.toString() ?? 'default',
    );
  }

  bool _skipRemoteMutation(String action) {
    if (!usesRemoteRpcData) {
      return false;
    }
    log.trace(
      'Skip $action for RPC-backed archive downloads '
      'in thin-client mode',
    );
    return true;
  }

  // --------------- End remote RPC helpers ---------------

  bool containArchive(int gid) {
    return archiveDownloadInfos.containsKey(gid);
  }

  bool isMitigationInProgress(int gid) {
    return _mitigationCompleters.containsKey(gid);
  }

  bool hasMitigationInProgress() {
    return _mitigationWorkerRunning ||
        _mitigationQueue.isNotEmpty ||
        _mitigationCompleters.isNotEmpty ||
        _runningMitigationGids.isNotEmpty;
  }

  bool interruptMitigation() {
    if (!hasMitigationInProgress()) {
      return false;
    }

    _mitigationSessionId++;
    _mitigationCancelToken.cancel('Archive mitigation interrupted');
    _mitigationCancelToken = CancelToken();

    _mitigationQueue.clear();
    _queuedMitigationGids.clear();

    for (final MapEntry<int, Completer<ArchiveMitigationReport>> entry
        in _mitigationCompleters.entries.toList(growable: false)) {
      if (_runningMitigationGids.contains(entry.key)) {
        continue;
      }

      if (!entry.value.isCompleted) {
        entry.value.complete(_interruptedMitigationReport(1));
      }

      _mitigationCompleters.remove(entry.key);
    }

    return true;
  }

  Future<void> downloadArchive(
    ArchiveDownloadedData archive, {
    bool resume = false,
    bool reParse = false,
  }) async {
    if (usesRemoteRpcData) {
      await rpcRequest.requestDownloadArchiveStart(
        archive: archive.toJson(),
        resume: resume,
        reParse: reParse,
      );
      unawaited(_refreshRemoteArchiveSnapshotSafely());
      return;
    }

    await _ensureDownloadDirExists();

    if (!resume) {
      if (archiveDownloadInfos.containsKey(archive.gid)) {
        return;
      }
      if (!await _initArchiveInfo(archive)) {
        return;
      }

      _generateComicInfoInDisk(archive);
    }

    final info = archiveDownloadInfos[archive.gid];
    if (info == null ||
        info.cancelToken.isCancelled ||
        info.archiveStatus.code <= ArchiveStatus.paused.code ||
        info.archiveStatus == ArchiveStatus.completed) {
      return;
    }
    final existingRun = _archiveRuns[archive.gid];
    if (existingRun != null) {
      return existingRun.future;
    }
    info.forceReparse |= reParse;
    if (info.archiveStatus.code < ArchiveStatus.downloaded.code) {
      final isolates =
          info.downloadTask?.isolateCount ?? downloadSetting.archiveDownloadIsolateCount.value;
      if (downloadSetting.manageArchiveDownloadConcurrency.isTrue &&
          _reservedIsolateCount() + isolates > _maxIsolateCountsTotal) {
        // Queuing must not redeem a link or spend GP. Reserve capacity before
        // any unlock/resolve request, including for tasks restored from disk.
        return _updateArchiveStatus(archive.gid, ArchiveStatus.waitingIsolate);
      }
      _archiveSlots[archive.gid] = isolates;
    }
    final run = Completer<void>();
    _archiveRuns[archive.gid] = run;
    final session = info.cancelToken;
    bool isCurrent() =>
        !session.isCancelled &&
        identical(archiveDownloadInfos[archive.gid], info) &&
        identical(info.cancelToken, session);
    try {
      if (info.archiveStatus == ArchiveStatus.waitingIsolate) {
        await _updateArchiveStatus(archive.gid, ArchiveStatus.unlocking);
      }
      log.info('Begin to handle archive: ${archive.title}, original: ${archive.isOriginal}');
      if (!isCurrent()) {
        return;
      }
      await _unlock(archive);
      if (!isCurrent()) {
        return;
      }
      await _getDownloadPageUrl(archive);
      if (!isCurrent()) {
        return;
      }
      await _getDownloadUrl(archive, reParse: info.forceReparse);
      if (!isCurrent()) {
        return;
      }
      await _doDownloadArchiveViaMultiIsolate(archive);
      if (!isCurrent()) {
        return;
      }
      await _unpackingArchive(archive);
    } finally {
      _archiveSlots.remove(archive.gid);
      _archiveRuns.remove(archive.gid);
      run.complete();
      unawaited(_tryWakeWaitingTasks());
    }
  }

  Future<void> deleteArchive(int gid) async {
    if (usesRemoteRpcData) {
      await rpcRequest.requestDownloadArchiveDelete(gid: gid);
      unawaited(_refreshRemoteArchiveSnapshotSafely());
      return;
    }

    ArchiveDownloadedData? archive = archives.firstWhereOrNull(
      (archive) => archive.gid == gid,
    );
    if (archive != null) {
      log.info('Delete archive: ${archive.title}, original: ${archive.isOriginal}');

      await pauseDownloadArchive(gid);

      await superResolutionService.deleteSuperResolve(gid, SuperResolutionType.archive);

      await _deleteArchiveInfoInDatabase(gid);

      await _deleteArchiveInDisk(archive);

      _deleteArchiveInMemory(gid);

      update(['$archiveStatusId::${archive.gid}']);
    }
  }

  Future<void> pauseAllDownloadArchive() async {
    if (usesRemoteRpcData) {
      await rpcRequest.requestDownloadArchivePauseAll();
      unawaited(_refreshRemoteArchiveSnapshotSafely());
      return;
    }
    await Future.wait(archives.map((a) => a.gid).map(pauseDownloadArchive).toList());
  }

  Future<void> pauseDownloadArchive(int gid, {bool needReUnlock = false}) async {
    if (usesRemoteRpcData) {
      await rpcRequest.requestDownloadArchivePause(gid: gid);
      unawaited(_refreshRemoteArchiveSnapshotSafely());
      return;
    }

    ArchiveDownloadedData? archive = archives.firstWhereOrNull(
      (archive) => archive.gid == gid,
    );
    if (archive != null) {
      ArchiveDownloadInfo archiveDownloadInfo = archiveDownloadInfos[gid]!;
      if (archiveDownloadInfo.archiveStatus.code <= ArchiveStatus.paused.code ||
          archiveDownloadInfo.archiveStatus.code >= ArchiveStatus.downloaded.code) {
        return;
      }

      log.info('Pause archive: ${archive.title}, original: ${archive.isOriginal}');

      final Future<void> statusUpdate = _updateArchiveStatus(
          gid, needReUnlock ? ArchiveStatus.needReUnlock : ArchiveStatus.paused);
      archiveDownloadInfo.cancelToken.cancel();
      await archiveDownloadInfo.downloadTask?.pause();
      if (archiveDownloadInfo.downloadCompleter?.isCompleted == false) {
        archiveDownloadInfo.downloadCompleter!.completeError(CancelException());
      }
      archiveDownloadInfo.downloadCompleter = null;
      archiveDownloadInfo.speedComputer.pause();
      await statusUpdate;

      _tryWakeWaitingTasks();
    }
  }

  Future<void> resumeAllDownloadArchive() async {
    if (usesRemoteRpcData) {
      await rpcRequest.requestDownloadArchiveResumeAll();
      unawaited(_refreshRemoteArchiveSnapshotSafely());
      return;
    }
    await Future.wait(archives.map((a) => a.gid).map(resumeDownloadArchive).toList());
  }

  Future<void> resumeDownloadArchive(int gid) async {
    if (usesRemoteRpcData) {
      await rpcRequest.requestDownloadArchiveResume(gid: gid);
      unawaited(_refreshRemoteArchiveSnapshotSafely());
      return;
    }

    ArchiveDownloadedData? archive = archives.firstWhereOrNull(
      (archive) => archive.gid == gid,
    );
    if (archive != null) {
      ArchiveDownloadInfo archiveDownloadInfo = archiveDownloadInfos[archive.gid]!;
      if (archiveDownloadInfo.archiveStatus != ArchiveStatus.paused) {
        return;
      }

      log.info('Resume archive: ${archive.title}, original: ${archive.isOriginal}');

      await _archiveRuns[gid]?.future;
      if (!identical(archiveDownloadInfos[gid], archiveDownloadInfo) ||
          archiveDownloadInfo.archiveStatus != ArchiveStatus.paused) {
        return;
      }
      archiveDownloadInfo.cancelToken = CancelToken();
      await _updateArchiveStatus(gid, ArchiveStatus.unlocking);

      downloadArchive(archive, resume: true);
    }
  }

  /// Renew the server session without deleting the partial download on disk.
  Future<void> redeemArchiveAgain(int gid) async {
    final archive = archives.firstWhereOrNull((archive) => archive.gid == gid);
    final info = archiveDownloadInfos[gid];
    if (archive == null ||
        info == null ||
        info.archiveStatus.code >= ArchiveStatus.downloaded.code ||
        !_renewingArchives.add(gid)) {
      return;
    }
    try {
      await cancelArchive(gid);
      if (usesRemoteRpcData || info.archiveStatus == ArchiveStatus.unlocking) {
        await downloadArchive(archive, resume: true, reParse: true);
      }
    } finally {
      _renewingArchives.remove(gid);
    }
  }

  /// Cancel the expired server session, retaining local chunks for re-redemption.
  Future<void> cancelArchive(int gid) async {
    if (usesRemoteRpcData) {
      await rpcRequest.requestDownloadArchiveCancelTask(gid: gid);
      unawaited(_refreshRemoteArchiveSnapshotSafely());
      return;
    }

    ArchiveDownloadedData? archive = archives.firstWhereOrNull((a) => a.gid == gid);
    if (archive != null) {
      ArchiveDownloadInfo archiveDownloadInfo = archiveDownloadInfos[archive.gid]!;
      if (archiveDownloadInfo.archiveStatus.code >= ArchiveStatus.downloaded.code) {
        return;
      }

      log.download(
        'Cancel archive: ${archive.title}, original: ${archive.isOriginal}',
        level: Level.info,
      );

      archiveDownloadInfo.archiveStatus = ArchiveStatus.paused;
      archiveDownloadInfo.cancelToken.cancel();
      // Stop the old transfer before dropping its only owning reference.
      await archiveDownloadInfo.downloadTask?.pause();
      if (archiveDownloadInfo.downloadCompleter?.isCompleted == false) {
        archiveDownloadInfo.downloadCompleter!.completeError(CancelException());
      }
      await _archiveRuns[gid]?.future;
      archiveDownloadInfo.downloadPageUrl = null;
      archiveDownloadInfo.downloadUrl = null;
      archiveDownloadInfo.downloadTask = null;
      archiveDownloadInfo.downloadCompleter = null;
      archiveDownloadInfo.cancelToken = CancelToken();
      archiveDownloadInfo.archiveStatus = ArchiveStatus.unlocking;

      await _updateArchiveInDatabase(archive.gid);
      update(['$archiveStatusId::${archive.gid}']);

      _notifyDownloadActivityChanged();

      /// skip when use bot
      if (archiveDownloadInfo.parseSource == ArchiveParseSource.official.code) {
        try {
          await retry(
            () => ehRequest.requestCancelArchive(
              url: archive.archivePageUrl.replaceFirst('--', '-'),
              cancelToken: archiveDownloadInfo.cancelToken,
            ),
            retryIf: (e) => e is DioException && e.type != DioExceptionType.cancel,
            onRetry: (e) => log.download(
              'Cancel archive: ${archive.title} failed, retry. Reason: ${(e as DioException).message}',
              level: Level.warning,
            ),
            maxAttempts: _maxRetryTimes,
          );
        } on DioException catch (e) {
          if (e.type == DioExceptionType.cancel) {
            return;
          }

          log.download('Cancel archive error, reason: ${e.toString()}', level: Level.error);
          return pauseDownloadArchive(archive.gid);
        }
      }
    }
  }

  Future<void> migrate2Gallery(int gid) async {
    await mitigateCompletedOriginalArchives(gid: gid);
  }

  Future<ArchiveMitigationReport> mitigateCompletedOriginalArchives({int? gid}) async {
    if (gid != null) {
      return _enqueueMitigation(gid);
    }

    final List<int> gids = archives.map((archive) => archive.gid).toList(growable: false);
    if (gids.isEmpty) {
      return _emptyMitigationReport;
    }

    final List<ArchiveMitigationReport> reports = await Future.wait(
      gids.map(_enqueueMitigation).toList(growable: false),
    );

    return _mergeMitigationReports(reports);
  }

  Future<ArchiveMitigationReport> _enqueueMitigation(int gid) {
    final Completer<ArchiveMitigationReport>? existingCompleter = _mitigationCompleters[gid];
    if (existingCompleter != null) {
      return existingCompleter.future;
    }

    final Completer<ArchiveMitigationReport> completer = Completer<ArchiveMitigationReport>();
    _mitigationCompleters[gid] = completer;

    if (_queuedMitigationGids.add(gid)) {
      _mitigationQueue.add(gid);
      _startMitigationWorker();
    }

    return completer.future;
  }

  void _startMitigationWorker() {
    if (_mitigationWorkerRunning) {
      return;
    }

    _mitigationWorkerRunning = true;
    unawaited(_processMitigationQueue());
  }

  Future<void> _processMitigationQueue() async {
    final int sessionId = _mitigationSessionId;

    await wakelockService.acquire(_mitigationLockName);

    try {
      while (_mitigationQueue.isNotEmpty) {
        if (_isMitigationInterrupted(sessionId)) {
          break;
        }

        final int gid = _mitigationQueue.removeFirst();
        _queuedMitigationGids.remove(gid);

        final Completer<ArchiveMitigationReport>? completer = _mitigationCompleters[gid];
        if (completer == null || completer.isCompleted) {
          _mitigationCompleters.remove(gid);
          continue;
        }

        _runningMitigationGids.add(gid);

        try {
          final ArchiveMitigationReport report = await _mitigateSingleGallery(gid, sessionId);
          if (!completer.isCompleted) {
            completer.complete(report);
          }
        } on _MitigationInterruptedException {
          if (!completer.isCompleted) {
            completer.complete(_interruptedMitigationReport(1));
          }

          if (_isMitigationInterrupted(sessionId)) {
            break;
          }
        } on Exception catch (e, s) {
          log.error('Mitigation queue task failed: gid=$gid', e, s);
          if (!completer.isCompleted) {
            completer.complete(_failedMitigationReport(1));
          }
        } finally {
          _runningMitigationGids.remove(gid);
          _mitigationCompleters.remove(gid);
        }

        if (_isMitigationInterrupted(sessionId)) {
          break;
        }

        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    } finally {
      await wakelockService.release(_mitigationLockName);

      _mitigationWorkerRunning = false;
      if (_mitigationQueue.isNotEmpty) {
        _startMitigationWorker();
      }
    }
  }

  Future<ArchiveMitigationReport> _mitigateSingleGallery(int gid, int sessionId) async {
    _throwIfMitigationInterrupted(sessionId);

    final ArchiveDownloadedData? archive = archives.firstWhereOrNull(
      (archive) => archive.gid == gid,
    );
    if (archive == null) {
      return _emptyMitigationReport;
    }

    if (galleryDownloadService.usesRemoteRpcData) {
      log.warning('Skip archive mitigation in RPC thin-client mode. gid=$gid');
      return (checked: 1, migrated: 0, replaced: 0, keptOriginal: 0, skipped: 1, failed: 0);
    }

    final ArchiveDownloadInfo? archiveDownloadInfo = archiveDownloadInfos[archive.gid];
    if (archiveDownloadInfo == null ||
        archiveDownloadInfo.archiveStatus != ArchiveStatus.completed) {
      return (checked: 1, migrated: 0, replaced: 0, keptOriginal: 0, skipped: 1, failed: 0);
    }

    if (!archive.isOriginal) {
      log.info('Skip low quality archive mitigation: gid=${archive.gid}');
      return (checked: 1, migrated: 0, replaced: 0, keptOriginal: 0, skipped: 1, failed: 0);
    }

    final _ArchiveMitigationOutcome outcome = await _mitigateSingleArchiveToDownload(
      archive,
      archiveDownloadInfo,
      sessionId,
    );

    switch (outcome) {
      case _ArchiveMitigationOutcome.migrated:
        return (checked: 1, migrated: 1, replaced: 0, keptOriginal: 0, skipped: 0, failed: 0);
      case _ArchiveMitigationOutcome.replaced:
        return (checked: 1, migrated: 0, replaced: 1, keptOriginal: 0, skipped: 0, failed: 0);
      case _ArchiveMitigationOutcome.keptOriginal:
        return (checked: 1, migrated: 0, replaced: 0, keptOriginal: 1, skipped: 0, failed: 0);
      case _ArchiveMitigationOutcome.skipped:
        return (checked: 1, migrated: 0, replaced: 0, keptOriginal: 0, skipped: 1, failed: 0);
      case _ArchiveMitigationOutcome.failed:
        return _failedMitigationReport(1);
    }
  }

  ArchiveMitigationReport _mergeMitigationReports(List<ArchiveMitigationReport> reports) {
    int checked = 0;
    int migrated = 0;
    int replaced = 0;
    int keptOriginal = 0;
    int skipped = 0;
    int failed = 0;

    for (final ArchiveMitigationReport report in reports) {
      checked += report.checked;
      migrated += report.migrated;
      replaced += report.replaced;
      keptOriginal += report.keptOriginal;
      skipped += report.skipped;
      failed += report.failed;
    }

    return (
      checked: checked,
      migrated: migrated,
      replaced: replaced,
      keptOriginal: keptOriginal,
      skipped: skipped,
      failed: failed,
    );
  }

  ArchiveMitigationReport _failedMitigationReport(int checked) {
    return (
      checked: checked,
      migrated: 0,
      replaced: 0,
      keptOriginal: 0,
      skipped: 0,
      failed: checked,
    );
  }

  ArchiveMitigationReport _interruptedMitigationReport(int checked) {
    return (
      checked: checked,
      migrated: 0,
      replaced: 0,
      keptOriginal: 0,
      skipped: checked,
      failed: 0,
    );
  }

  bool _isMitigationInterrupted(int sessionId) {
    return sessionId != _mitigationSessionId;
  }

  void _throwIfMitigationInterrupted(int sessionId) {
    if (_isMitigationInterrupted(sessionId)) {
      throw const _MitigationInterruptedException();
    }
  }

  static const ArchiveMitigationReport _emptyMitigationReport = (
    checked: 0,
    migrated: 0,
    replaced: 0,
    keptOriginal: 0,
    skipped: 0,
    failed: 0,
  );

  Future<_ArchiveMitigationOutcome> _mitigateSingleArchiveToDownload(
    ArchiveDownloadedData archive,
    ArchiveDownloadInfo archiveDownloadInfo,
    int sessionId,
  ) async {
    _throwIfMitigationInterrupted(sessionId);

    final GalleryDownloadedData? existingGallery =
        galleryDownloadService.gallerys.firstWhereOrNull((g) => g.gid == archive.gid);
    final String? existingGalleryDir = existingGallery == null
        ? null
        : galleryDownloadService.computeGalleryDownloadAbsolutePath(
            existingGallery.title,
            existingGallery.gid,
          );

    if (existingGallery != null && existingGallery.downloadOriginalImage) {
      log.info('Keep existing original download for gid=${archive.gid}, remove archive copy.');
      await deleteArchive(archive.gid);
      return _ArchiveMitigationOutcome.keptOriginal;
    }

    final GalleryMetadata? metadata = await _requestGalleryMetadata(
      archive,
      sessionId: sessionId,
    );
    if (metadata == null) {
      log.warning('Skip archive mitigation due to metadata fetch failure. gid=${archive.gid}');
      return _ArchiveMitigationOutcome.skipped;
    }

    _throwIfMitigationInterrupted(sessionId);

    final List<GalleryImage> images = await getUnpackedImages(
      archive.gid,
      computeHash: true,
      shouldInterrupt: () => _isMitigationInterrupted(sessionId),
    );
    if (images.length != metadata.pageCount) {
      log.warning(
        'Skip archive mitigation due to image count mismatch. gid=${archive.gid}, images=${images.length}, expected=${metadata.pageCount}',
      );
      return _ArchiveMitigationOutcome.skipped;
    }

    _throwIfMitigationInterrupted(sessionId);

    try {
      if (existingGallery != null) {
        log.info('Replace low quality gallery with original archive for gid=${archive.gid}.');
        // Keep old files until new import is persisted to reduce risk on crash.
        await galleryDownloadService.deleteGallery(existingGallery, deleteImages: false);
      }

      final GalleryDownloadedData galleryDownloadedData = _buildGalleryFromArchiveAndMetadata(
        archive,
        archiveDownloadInfo.group,
        metadata,
      );

      await galleryDownloadService.importGallery(galleryDownloadedData, images);
      if (!galleryDownloadService.containGallery(archive.gid)) {
        log.error('Archive mitigation import failed: gid=${archive.gid}');
        return _ArchiveMitigationOutcome.failed;
      }

      if (existingGalleryDir != null) {
        final String newGalleryDir = galleryDownloadService.computeGalleryDownloadAbsolutePath(
          galleryDownloadedData.title,
          galleryDownloadedData.gid,
        );
        if (existingGalleryDir != newGalleryDir) {
          final Directory oldDirectory = Directory(existingGalleryDir);
          if (await oldDirectory.exists()) {
            await oldDirectory.delete(recursive: true);
          }
        }
      }

      await deleteArchive(archive.gid);
      return existingGallery == null
          ? _ArchiveMitigationOutcome.migrated
          : _ArchiveMitigationOutcome.replaced;
    } on Exception catch (e, s) {
      log.error('Archive mitigation failed: gid=${archive.gid}', e, s);
      return _ArchiveMitigationOutcome.failed;
    }
  }

  Future<GalleryMetadata?> _requestGalleryMetadata(
    ArchiveDownloadedData archive, {
    required int sessionId,
  }) async {
    try {
      return await retry(
        () => ehRequest.requestGalleryMetadata<GalleryMetadata>(
          gid: archive.gid,
          token: archive.token,
          cancelToken: _mitigationCancelToken,
          parser: EHSpiderParser.galleryMetadataJson2GalleryMetadata,
        ),
        retryIf: (e) => e is DioException && e.type != DioExceptionType.cancel,
        maxAttempts: _maxRetryTimes,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel && _isMitigationInterrupted(sessionId)) {
        throw const _MitigationInterruptedException();
      }

      log.error('Fetch gallery metadata failed. gid=${archive.gid}', e);
      return null;
    } on EHSiteException catch (e) {
      log.error('Fetch gallery metadata failed. gid=${archive.gid}', e);
      return null;
    } on Exception catch (e, s) {
      log.error('Fetch gallery metadata failed. gid=${archive.gid}', e, s);
      return null;
    }
  }

  GalleryDownloadedData _buildGalleryFromArchiveAndMetadata(
    ArchiveDownloadedData archive,
    String group,
    GalleryMetadata metadata,
  ) {
    final String normalizedTitle =
        metadata.japaneseTitle.isNotEmpty ? metadata.japaneseTitle : metadata.title;
    final String now = DateTime.now().toString();

    return GalleryDownloadedData(
      gid: metadata.galleryUrl.gid,
      token: metadata.galleryUrl.token,
      title: normalizedTitle,
      category: metadata.category,
      pageCount: metadata.pageCount,
      galleryUrl: metadata.galleryUrl.url,
      uploader: metadata.uploader,
      publishTime: metadata.publishTime,
      downloadStatusIndex: DownloadStatus.downloaded.index,
      downloadOriginalImage: true,
      sortOrder: 0,
      groupName: group,
      insertTime: now,
      priority: GalleryDownloadService.defaultDownloadGalleryPriority,
      tags: tagMap2TagString(metadata.tags),
      tagRefreshTime: now,
    );
  }

  Future<void> _tryAutoMitigateArchiveToDownload(int gid) async {
    if (advancedSetting.enableAutoMitigateArchiveToDownload.isFalse) {
      return;
    }

    final ArchiveMitigationReport report = await mitigateCompletedOriginalArchives(gid: gid);
    log.info(
      'Auto archive mitigation finished. gid=$gid, migrated=${report.migrated}, replaced=${report.replaced}, keptOriginal=${report.keptOriginal}, skipped=${report.skipped}, failed=${report.failed}',
    );
  }

  Future<bool> updateArchiveGroup(int gid, String group) async {
    if (usesRemoteRpcData) {
      await rpcRequest.requestDownloadArchiveUpdateGroup(gid: gid, group: group);
      unawaited(_refreshRemoteArchiveSnapshotSafely());
      return true;
    }

    ArchiveDownloadInfo? archiveDownloadInfo = archiveDownloadInfos[gid];
    if (archiveDownloadInfo == null) {
      return false;
    }

    archiveDownloadInfo.group = group;

    if (!allGroups.contains(group)) {
      if (!await _addGroup(group)) {
        return false;
      }
    }

    _sortArchives();

    return _updateArchiveInDatabase(gid);
  }

  Future<void> renameGroup(String oldGroup, String newGroup) async {
    if (usesRemoteRpcData) {
      await rpcRequest.requestDownloadArchiveRenameGroup(
        oldGroup: oldGroup,
        newGroup: newGroup,
      );
      unawaited(_refreshRemoteArchiveSnapshotSafely());
      return;
    }

    List<ArchiveDownloadedData> archiveDownloadedDatas =
        archives.where((a) => archiveDownloadInfos[a.gid]!.group == oldGroup).toList();

    await appDb.transaction(() async {
      if (!allGroups.contains(newGroup)) {
        int index = allGroups.indexOf(oldGroup);
        allGroups[index] = newGroup;
        await ArchiveGroupDao.insertArchiveGroup(
          ArchiveGroupData(groupName: newGroup, sortOrder: index),
        );
      }

      for (ArchiveDownloadedData a in archiveDownloadedDatas) {
        archiveDownloadInfos[a.gid]!.group = newGroup;
        await _updateArchiveInDatabase(a.gid);
      }

      await deleteGroup(oldGroup);
    });

    _sortArchives();
  }

  Future<bool> deleteGroup(String group) async {
    if (usesRemoteRpcData) {
      await rpcRequest.requestDownloadArchiveDeleteGroup(group: group);
      unawaited(_refreshRemoteArchiveSnapshotSafely());
      return true;
    }

    allGroups.remove(group);

    try {
      return (await ArchiveGroupDao.deleteArchiveGroup(group) > 0);
    } on Exception catch (e) {
      log.info(e);
      return false;
    }
  }

  Future<void> updateGroupOrder(int beforeIndex, int afterIndex) async {
    if (afterIndex == allGroups.length - 1) {
      allGroups.add(allGroups.removeAt(beforeIndex));
    } else {
      allGroups.insert(afterIndex, allGroups.removeAt(beforeIndex));
    }

    log.info('Update group order: $allGroups');

    await appDb.transaction(() async {
      for (int i = 0; i < allGroups.length; i++) {
        await ArchiveGroupDao.updateArchiveGroupOrder(allGroups[i], i);
      }
    });
  }

  Future<void> changeParseSource(int gid, ArchiveParseSource parseSource) async {
    if (usesRemoteRpcData) {
      await rpcRequest.requestDownloadArchiveChangeParseSource(
        gid: gid,
        parseSource: parseSource.code,
      );
      unawaited(_refreshRemoteArchiveSnapshotSafely());
      return;
    }

    log.info('Update parse source: $gid $parseSource');

    ArchiveDownloadInfo? archiveDownloadInfo = archiveDownloadInfos[gid];
    if (archiveDownloadInfo == null) {
      return;
    }

    if (archiveDownloadInfo.archiveStatus.code >= ArchiveStatus.downloaded.code) {
      return;
    }

    archiveDownloadInfo.downloadUrl = null;
    archiveDownloadInfo.parseSource = parseSource.code;

    await _updateArchiveInDatabase(gid);

    update(['$archiveStatusId::$gid']);
  }

  Future<void> batchUpdateArchiveInDatabase(List<ArchiveDownloadedData> archives) async {
    await appDb.transaction(() async {
      for (ArchiveDownloadedData archive in archives) {
        await _updateArchiveInDatabase(archive.gid);
      }
    });

    _sortArchives();
  }

  /// Use meta in each archive folder to restore download tasks, then sync to database.
  /// this is used after re-install app, or share download folder to another user.
  Future<int> restoreTasks() async {
    if (_skipRemoteMutation('restoreTasks')) {
      return 0;
    }

    await completed;

    Directory downloadDir = Directory(downloadSetting.downloadPath.value);
    if (!await downloadDir.exists()) {
      return 0;
    }

    int restoredCount = 0;
    await for (FileSystemEntity galleryDir in downloadDir.list()) {
      File metadataFile = File(join(galleryDir.path, metadataFileName));

      /// metadata file does not exist
      if (!await metadataFile.exists()) {
        continue;
      }

      final String metadataContents = await metadataFile.readAsString();
      Map metadata = await isolateService.jsonDecodeAsync(metadataContents);

      /// compatible with new field
      metadata.putIfAbsent('sortOrder', () => 0);
      metadata.putIfAbsent('archiveStatusCode', () => ArchiveStatus.completed.code);
      if (metadata['groupName'] == null) {
        metadata['groupName'] = 'default'.tr;
      }
      if (metadata['tags'] == null) {
        metadata['tags'] = '';
      }
      if (metadata['tagRefreshTime'] == null) {
        metadata['tagRefreshTime'] = DateTime.now().toString();
      }
      if (metadata['parseSource'] == null) {
        metadata['parseSource'] = ArchiveParseSource.official.code;
      }

      ArchiveDownloadedData archive = ArchiveDownloadedData.fromJson(
        metadata as Map<String, dynamic>,
      );

      archive = archive.copyWith(archiveStatusCode: ArchiveStatus.completed.code);

      if (!await _saveArchiveAndGroupInDatabase(archive)) {
        log.error('Restore archive failed: $archive');
        await deleteArchive(archive.gid);
        continue;
      }

      _initArchiveInMemory(archive, sort: false);

      /// Persist the corrected snapshot back to the real unpacking directory's
      /// metadata file so future installs / transfers no longer need to re-apply
      /// the legacy naming compatibility. A metadata write failure is logged and
      /// does not roll back the successful restore.
      try {
        await _saveArchiveInfoInDisk(archive);
      } catch (e, st) {
        log.error('Save restored archive metadata failed, gid: ${archive.gid}', e, st);
      }

      restoredCount++;
      await Future<void>.delayed(Duration.zero);
    }

    if (restoredCount > 0) {
      _sortArchives();
    }

    return restoredCount;
  }

  Future<List<GalleryImage>> getUnpackedImages(
    int gid, {
    bool computeHash = false,
    bool Function()? shouldInterrupt,
  }) async {
    final ArchiveDownloadedData archive = archives.firstWhere((a) => a.gid == gid);
    final Directory directory = Directory(
      computeArchiveUnpackingPath(archive.title, archive.gid),
    );
    final String visibleDir = pathService.getVisibleDir().path;

    final List<FileSystemEntity> files = await directory.list().toList();
    final List<File> imageFiles =
        files.whereType<File>().where((file) => FileUtil.isImageExtension(file.path)).toList();
    imageFiles.sort(FileUtil.naturalCompareFile);

    final List<GalleryImage> images = imageFiles
        .map(
          (file) => GalleryImage(
            url: '',
            path: relative(file.path, from: visibleDir),
            downloadStatus: DownloadStatus.downloaded,
          ),
        )
        .toList(growable: false);

    if (!computeHash || images.isEmpty) {
      return images;
    }

    for (int batchStart = 0;
        batchStart < images.length;
        batchStart += _mitigationHashBatchSize) {
      if (shouldInterrupt?.call() ?? false) {
        throw const _MitigationInterruptedException();
      }

      final int batchEnd = min(batchStart + _mitigationHashBatchSize, images.length);
      for (int cursor = batchStart; cursor < batchEnd; cursor += _mitigationHashConcurrency) {
        final int chunkEnd = min(cursor + _mitigationHashConcurrency, batchEnd);

        final List<Future<String>> hashFutures = <Future<String>>[];
        for (int index = cursor; index < chunkEnd; index++) {
          final GalleryImage image = images[index];
          hashFutures.add(
            isolateService.run(
              FileUtil.computeSha1HashFromPath,
              join(visibleDir, image.path),
              debugLabel: 'archive-mitigation-hash',
            ),
          );
        }

        final List<String> hashes = await Future.wait(hashFutures);
        for (int offset = 0; offset < hashes.length; offset++) {
          images[cursor + offset].imageHash = hashes[offset];
        }

        if (shouldInterrupt?.call() ?? false) {
          throw const _MitigationInterruptedException();
        }
      }

      await Future<void>.delayed(Duration.zero);
    }

    return images;
  }

  Future<void> _generateComicInfoInDisk(ArchiveDownloadedData archive) async {
    GalleryDetail galleryDetail;
    try {
      ({GalleryDetail galleryDetails, String apikey}) detailPageInfo = await retry(
        () => ehRequest.requestDetailPage(
          galleryUrl: archive.galleryUrl,
          parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey,
        ),
        retryIf: (e) => e is DioException,
        maxAttempts: _maxRetryTimes,
      );
      galleryDetail = detailPageInfo.galleryDetails;
    } catch (e) {
      log.error('Get gallery detail failed, gallery: ${archive.gid}', e);
      return;
    }

    if (!archiveDownloadInfos.containsKey(archive.gid)) {
      return;
    }

    EHGalleryComicInfo galleryComicInfo = EHGalleryComicInfo(
      rawTitle: galleryDetail.rawTitle,
      japaneseTitle: galleryDetail.japaneseTitle,
      category: galleryDetail.category,
      pageCount: galleryDetail.pageCount,
      galleryUrl: galleryDetail.galleryUrl.url,
      uploader: galleryDetail.uploader,
      publishTime: galleryDetail.publishTime,
      languageAbbreviation:
          LocaleConsts.language2Abbreviation[galleryDetail.language]?.toLowerCase(),
      tagDatas:
          galleryDetail.tags.values.flattened.map((galleryTag) => galleryTag.tagData).toList(),
      rating: galleryDetail.realRating,
    );

    try {
      File file = File(
        join(computeArchiveUnpackingPath(archive.title, archive.gid), 'ComicInfo.xml'),
      );
      if (!await file.exists()) {
        await file.create(recursive: true);
      }
      await file.writeAsString(galleryComicInfo.toXmlDocument().toXmlString(pretty: true));
    } catch (e) {
      log.error('Write comic info failed, gallery: ${archive.gid}', e);
    }
  }

  String _computeArchiveTitle(String rawTitle) {
    String title = rawTitle.replaceAll(RegExp(r'[/|?,:*"<>\\.]'), ' ').trim();

    if (title.length > _maxTitleLength) {
      title = title.substring(0, _maxTitleLength).trim();
    }

    return title;
  }

  String computePackingFileDownloadPath(ArchiveDownloadedData archive) {
    String title = _computeArchiveTitle(archive.title);

    return join(downloadSetting.downloadPath.value, 'ArchiveV2 - ${archive.gid} - $title.zip');
  }

  String computeArchiveUnpackingPath(String rawTitle, int gid) {
    String title = _computeArchiveTitle(rawTitle);

    return join(downloadSetting.downloadPath.value, 'Archive - $gid - $title');
  }

  void _sortArchives() {
    archives.sort((a, b) {
      ArchiveDownloadInfo aInfo = archiveDownloadInfos[a.gid]!;
      ArchiveDownloadInfo bInfo = archiveDownloadInfos[b.gid]!;

      if (!(aInfo.group == 'default'.tr && bInfo.group == 'default'.tr)) {
        if (aInfo.group == 'default'.tr) {
          return 1;
        }
        if (bInfo.group == 'default'.tr) {
          return -1;
        }
      }

      int gResult = aInfo.group.compareTo(bInfo.group);
      if (gResult != 0) {
        return gResult;
      }

      int aOrder = aInfo.sortOrder;
      int bOrder = bInfo.sortOrder;
      if (aOrder - bOrder != 0) {
        return aOrder - bOrder;
      }

      DateTime aTime = DateFormat('yyyy-MM-dd HH:mm:ss').parse(a.insertTime);
      DateTime bTime = DateFormat('yyyy-MM-dd HH:mm:ss').parse(b.insertTime);

      return bTime.difference(aTime).inMilliseconds;
    });
  }

  JDownloadTask _generateDownloadTask(String url, ArchiveDownloadedData archive) {
    final ArchiveDownloadInfo owner = archiveDownloadInfos[archive.gid]!;
    JDownloadTask? task;
    bool isCurrent() =>
        identical(archiveDownloadInfos[archive.gid], owner) &&
        task != null &&
        identical(owner.downloadTask, task);
    task = JDownloadTask.newTask(
      url: url,
      savePath: computePackingFileDownloadPath(archive),
      isolateCount: downloadSetting.archiveDownloadIsolateCount.value,
      contentLengthRetryPolicy: ContentLengthRetryPolicy.forArchiveSize(owner.size),
      deleteWhenUrlMismatch: false,
      proxyConfig: ehRequest.currentProxyConfig(),
      headConnectionTimeout: Duration(milliseconds: networkSetting.connectTimeout.value),
      headReceiveTimeout: Duration(milliseconds: networkSetting.receiveTimeout.value),
      onProgress: (current, total) {
        if (!isCurrent()) {
          return;
        }
        owner.speedComputer.downloadedBytes = current;
        if (total != owner.size) {
          owner.size = total;
          _updateArchiveInDatabase(archive.gid);
        }
      },
      onDone: () {
        if (isCurrent() && owner.downloadCompleter?.isCompleted == false) {
          owner.downloadCompleter!.complete();
        }
      },
      onError: (JDownloadException e) {
        if (isCurrent() && owner.downloadCompleter?.isCompleted == false) {
          owner.downloadCompleter!.completeError(e);
        }
      },
      lookup: dohService.lookup,
      enableDnsOverHttps: networkSetting.enableDnsOverHttps.value,
      dnsOverHttpsEndpoint: networkSetting.dnsOverHttpsEndpoint.value,
    );
    return task;
  }

  Future<void> _check410Reason(String url, ArchiveDownloadedData archive) async {
    try {
      await ehRequest.get(
        url: url,
        cancelToken: archiveDownloadInfos[archive.gid]?.cancelToken,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        return;
      }

      if (e.response?.statusCode != 410) {
        log.download(
          'Check archive  ${archive.title} 410 reason failed, pause task.',
          level: Level.warning,
        );
        return pauseDownloadArchive(archive.gid);
      }

      if (e.response!.data is String &&
          e.response!.data.contains(
            'You have clocked too many downloaded bytes on this gallery',
          )) {
        log.download('${'410Hints'.tr} Archive: ${archive.title}', level: Level.warning);
        snack('archiveError'.tr, '${'410Hints'.tr} : ${archive.title}', isShort: true);
        return pauseDownloadArchive(archive.gid, needReUnlock: true);
      } else if (e.response!.data is String &&
          e.response!.data.contains(
            'This archive session has been used from too many different locations',
          )) {
        log.download(
          'Archive session has been used from too many different locations! Archive: ${archive.title}',
          level: Level.warning,
        );
        snack(
          'archiveError'.tr,
          'This archive session has been used from too many different locations.',
          isShort: true,
        );
        return pauseDownloadArchive(archive.gid, needReUnlock: true);
      } else if (e.response!.data is String &&
          e.response!.data.contains('IP quota exhausted')) {
        log.download('IP quota exhausted! Archive: ${archive.title}', level: Level.error);
        snack('archiveError'.tr, 'IP quota exhausted!', isShort: true);
        return pauseDownloadArchive(archive.gid, needReUnlock: true);
      } else if (e.response!.data is String &&
          e.response!.data.contains('Expired or invalid session')) {
        log.download(
          'Expired or invalid session! Archive: ${archive.title}',
          level: Level.warning,
        );
        snack('archiveError'.tr, 'Expired or invalid session!', isShort: true);
        return pauseDownloadArchive(archive.gid);
      } else {
        log.download(
          'Download archive 410, try re-parse. Archive: ${archive.title} Response: ${e.response!.data}',
          level: Level.warning,
        );

        final ArchiveDownloadInfo info = archiveDownloadInfos[archive.gid]!;
        await info.downloadTask?.pause();
        info.downloadTask = null;
        info.downloadUrl = null;
        await _updateArchiveStatus(archive.gid, ArchiveStatus.parsedDownloadPageUrl);

        await _getDownloadUrl(archive, reParse: true);
        return _doDownloadArchiveViaMultiIsolate(archive);
      }
    }

    return _doDownloadArchiveViaMultiIsolate(archive);
  }

  int _reservedIsolateCount() {
    return _archiveSlots.entries.fold(0, (count, entry) {
      final info = archiveDownloadInfos[entry.key];
      if (info == null || info.archiveStatus.code >= ArchiveStatus.downloaded.code) {
        return count;
      }
      return count + (info.downloadTask?.isolateCount ?? entry.value);
    });
  }

  Future<void> _tryWakeWaitingTasks() async {
    int currentActiveIsolateCount = _reservedIsolateCount();
    if (downloadSetting.manageArchiveDownloadConcurrency.isTrue &&
        currentActiveIsolateCount >= _maxIsolateCountsTotal) {
      return;
    }

    List<int> gids = archiveDownloadInfos.entries
        .where((e) => e.value.archiveStatus == ArchiveStatus.waitingIsolate)
        .map((e) => e.key)
        .toList();
    List<ArchiveDownloadedData> waitingArchives =
        archives.where((a) => gids.contains(a.gid)).toList();
    waitingArchives.sort((a, b) => a.insertTime.compareTo(b.insertTime));

    for (ArchiveDownloadedData a in waitingArchives) {
      ArchiveDownloadInfo archiveDownloadInfo = archiveDownloadInfos[a.gid]!;
      final isolates = archiveDownloadInfo.downloadTask?.isolateCount ??
          downloadSetting.archiveDownloadIsolateCount.value;
      if (downloadSetting.manageArchiveDownloadConcurrency.isFalse ||
          currentActiveIsolateCount + isolates <= _maxIsolateCountsTotal) {
        log.download('Archive ${a.title} gain isolates.', level: Level.info);
        unawaited(downloadArchive(a, resume: true));
        currentActiveIsolateCount += isolates;
      }
    }
  }

  void _onIsolateCountChange() {
    for (ArchiveDownloadInfo archiveDownloadInfo in archiveDownloadInfos.values) {
      if (archiveDownloadInfo.archiveStatus.code <= ArchiveStatus.unpacking.code &&
          archiveDownloadInfo.downloadTask != null) {
        archiveDownloadInfo.downloadTask!.changeIsolateCount(
          downloadSetting.archiveDownloadIsolateCount.value,
        );
      }
    }
    unawaited(_tryWakeWaitingTasks());
  }

  void _onProxyConfigChange() {
    for (ArchiveDownloadInfo archiveDownloadInfo in archiveDownloadInfos.values) {
      if (archiveDownloadInfo.archiveStatus.code <= ArchiveStatus.downloading.code &&
          archiveDownloadInfo.downloadTask != null) {
        archiveDownloadInfo.downloadTask!.setProxy(ehRequest.currentProxyConfig());
      }
    }
  }

  void _onTimeoutChange() {
    for (ArchiveDownloadInfo archiveDownloadInfo in archiveDownloadInfos.values) {
      if (archiveDownloadInfo.archiveStatus.code <= ArchiveStatus.unpacking.code &&
          archiveDownloadInfo.downloadTask != null) {
        archiveDownloadInfo.downloadTask!.changeConnectionTimeout(
          Duration(milliseconds: networkSetting.connectTimeout.value),
        );
        archiveDownloadInfo.downloadTask!.changeReceiveTimeout(
          Duration(milliseconds: networkSetting.receiveTimeout.value),
        );
      }
    }
  }

  bool _isTaskInStatus(int gid, List<ArchiveStatus> statuses) {
    return archiveDownloadInfos.containsKey(gid) &&
        statuses.contains(archiveDownloadInfos[gid]!.archiveStatus);
  }

  Future<void> _updateArchiveStatus(int gid, ArchiveStatus archiveStatus) async {
    ArchiveDownloadInfo archiveDownloadInfo = archiveDownloadInfos[gid]!;

    if (archiveDownloadInfo.archiveStatus != archiveStatus) {
      archiveDownloadInfo.archiveStatus = archiveStatus;
      await _updateArchiveInDatabase(gid);
      update(['$archiveStatusId::$gid']);
    }

    _notifyDownloadActivityChanged();
  }

  // TASKS

  Future<void> _unlock(ArchiveDownloadedData archive) async {
    ArchiveDownloadInfo archiveDownloadInfo = archiveDownloadInfos[archive.gid]!;

    if (!_isTaskInStatus(archive.gid, [ArchiveStatus.unlocking])) {
      return;
    }
    if (archiveDownloadInfo.downloadPageUrl != null) {
      archiveDownloadInfo.archiveStatus = ArchiveStatus.unlocked;
      _notifyDownloadActivityChanged();
      return;
    }
    if (archiveDownloadInfo.parseSource == ArchiveParseSource.bot.code) {
      archiveDownloadInfo.archiveStatus = ArchiveStatus.unlocked;
      _notifyDownloadActivityChanged();
      return;
    }

    log.download(
      'Begin to unlock archive: ${archive.title}, original: ${archive.isOriginal}',
      level: Level.info,
    );

    await _updateArchiveStatus(archive.gid, ArchiveStatus.unlocking);

    ArchiveUnlockResult result;
    try {
      result = await retry(
        () => ehRequest.requestUnlockArchive(
          url: archive.archivePageUrl.replaceFirst('--', '-'),
          isOriginal: archive.isOriginal,
          cancelToken: archiveDownloadInfo.cancelToken,
          parser: EHSpiderParser.unlockArchivePage2DownloadArchivePageUrl,
        ),
        retryIf: (e) => e is DioException && e.type != DioExceptionType.cancel,
        onRetry: (e) => log.download(
          'Request unlock archive: ${archive.title} failed, retry. Reason: ${(e as DioException).message}',
          level: Level.warning,
        ),
        maxAttempts: _maxRetryTimes,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        return;
      }
      return await _unlock(archive);
    } on EHSiteException catch (e) {
      log.download('Unlock archive error, reason: ${e.message}', level: Level.error);
      snack('archiveError'.tr, e.message, isShort: true);

      if (e.shouldPauseAllDownloadTasks) {
        return await pauseAllDownloadArchive();
      } else {
        return await pauseDownloadArchive(archive.gid);
      }
    }

    if (archiveDownloadInfo.cancelToken.isCancelled) {
      return;
    }
    if (result.success) {
      log.download(
        'Get archive download page url success: ${archive.title}',
        level: Level.info,
      );
      archiveDownloadInfo.downloadPageUrl = result.url;
      await _updateArchiveStatus(archive.gid, ArchiveStatus.unlocked);
    } else {
      log.download(
        'Unlock archive failed. Archive: ${archive.title}, reason: ${result.msg}',
        level: Level.error,
      );
      snack('archiveError'.tr, result.msg, isShort: true);
      await pauseDownloadArchive(archive.gid);
    }
  }

  Future<void> _getDownloadPageUrl(ArchiveDownloadedData archive) async {
    ArchiveDownloadInfo archiveDownloadInfo = archiveDownloadInfos[archive.gid]!;
    if (!_isTaskInStatus(archive.gid, [
      ArchiveStatus.unlocked,
      ArchiveStatus.parsingDownloadPageUrl,
    ])) {
      return;
    }
    if (archiveDownloadInfo.downloadPageUrl != null) {
      archiveDownloadInfo.archiveStatus = ArchiveStatus.parsedDownloadPageUrl;
      _notifyDownloadActivityChanged();
      return;
    }
    if (archiveDownloadInfo.parseSource == ArchiveParseSource.bot.code) {
      archiveDownloadInfo.archiveStatus = ArchiveStatus.parsedDownloadPageUrl;
      _notifyDownloadActivityChanged();
      return;
    }

    log.download(
      'Begin to circularly fetch archive download page url: ${archive.title}, original: ${archive.isOriginal}',
      level: Level.info,
    );

    await _updateArchiveStatus(archive.gid, ArchiveStatus.parsingDownloadPageUrl);

    ArchiveUnlockResult result;
    try {
      result = await retry(
        () => ehRequest.requestUnlockArchive(
          url: archive.archivePageUrl.replaceFirst('--', '-'),
          isOriginal: archive.isOriginal,
          cancelToken: archiveDownloadInfo.cancelToken,
          parser: EHSpiderParser.unlockArchivePage2DownloadArchivePageUrl,
        ),
        retryIf: (e) => e is DioException && e.type != DioExceptionType.cancel,
        onRetry: (e) => log.download(
          'Request unlock archive: ${archive.title} failed, retry. Reason: ${(e as DioException).message}',
          level: Level.warning,
        ),
        maxAttempts: _maxRetryTimes,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        return;
      }
      return await _unlock(archive);
    } on EHSiteException catch (e) {
      log.download(
        'Parsing archive download page url failed, reason: ${e.message}',
        level: Level.error,
      );
      snack('archiveError'.tr, e.message, isShort: true);

      if (e.shouldPauseAllDownloadTasks) {
        return pauseAllDownloadArchive();
      } else {
        return pauseDownloadArchive(archive.gid);
      }
    }

    if (archiveDownloadInfo.cancelToken.isCancelled) {
      return;
    }
    if (result.success && result.url != null) {
      log.download(
        'Get archive download page url success: ${archive.title}',
        level: Level.info,
      );
      archiveDownloadInfo.downloadPageUrl = result.url;
      await _updateArchiveStatus(archive.gid, ArchiveStatus.parsedDownloadPageUrl);
    } else if (result.success && result.url == null) {
      /// wait for server operation
      await Future.delayed(const Duration(milliseconds: 1000));
      return _getDownloadPageUrl(archive);
    } else {
      log.download(
        'Get archive download page url failed. Archive: ${archive.title}, reason: ${result.msg}',
        level: Level.error,
      );
      snack('archiveError'.tr, result.msg, isShort: true);
      await pauseDownloadArchive(archive.gid);
      return;
    }
  }

  Future<void> _getDownloadUrl(ArchiveDownloadedData archive, {bool reParse = false}) async {
    ArchiveDownloadInfo archiveDownloadInfo = archiveDownloadInfos[archive.gid]!;
    if (!_isTaskInStatus(archive.gid, [
      ArchiveStatus.parsedDownloadPageUrl,
      ArchiveStatus.parsingDownloadUrl,
    ])) {
      return;
    }
    if (archiveDownloadInfo.downloadUrl != null) {
      archiveDownloadInfo.archiveStatus = ArchiveStatus.parsedDownloadUrl;
      _notifyDownloadActivityChanged();
      return;
    }

    /// changed parse source from bot to official
    if (archiveDownloadInfo.parseSource == ArchiveParseSource.official.code &&
        archiveDownloadInfo.downloadPageUrl == null) {
      archiveDownloadInfo.archiveStatus = ArchiveStatus.unlocked;
      _notifyDownloadActivityChanged();
      await _getDownloadPageUrl(archive);
      if (!_isTaskInStatus(archive.gid, [ArchiveStatus.parsedDownloadPageUrl])) {
        return;
      }
    }

    log.download(
      'Begin to parse fetch archive download url: ${archive.title}, original: ${archive.isOriginal}, parseSource: ${archive.parseSource}',
      level: Level.info,
    );

    await _updateArchiveStatus(archive.gid, ArchiveStatus.parsingDownloadUrl);

    String downloadPath;

    if (archiveDownloadInfo.parseSource == ArchiveParseSource.official.code) {
      try {
        downloadPath = await retry(
          () => ehRequest.get(
            url: archiveDownloadInfo.downloadPageUrl!,
            cancelToken: archiveDownloadInfo.cancelToken,
            parser: EHSpiderParser.downloadArchivePage2DownloadUrl,
          ),
          retryIf: (e) => e is DioException && e.type != DioExceptionType.cancel,
          onRetry: (e) => log.download(
            'Parse archive download url: ${archive.title} failed, retry. Reason: ${(e as DioException).message}',
            level: Level.warning,
          ),
          maxAttempts: _maxRetryTimes,
        );
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          return;
        }

        return await _getDownloadUrl(archive);
      } on EHSiteException catch (e) {
        log.download('Download error, reason: ${e.message}', level: Level.error);
        snack('archiveError'.tr, e.message, isShort: true);

        if (e.shouldPauseAllDownloadTasks) {
          return pauseAllDownloadArchive();
        } else {
          return pauseDownloadArchive(archive.gid);
        }
      } catch (e) {
        log.download('Parse archive download url error, reason: $e', level: Level.error);
        snack('archiveError'.tr, e.toString(), isShort: true);
        return pauseDownloadArchive(archive.gid);
      }
    } else {
      if (!archiveBotSetting.isReady) {
        snack('archiveError'.tr, 'pauseDownloadByInvalidArchiveBotKey'.tr);
        return pauseDownloadArchive(archive.gid);
      }

      try {
        ArchiveBotResponse response = await retry(
          () => archiveBotRequest.requestResolve(
            apiAddress: archiveBotSetting.apiAddress.value,
            apiKey: archiveBotSetting.apiKey.value!,
            gid: archive.gid,
            token: archive.token,
            reParse: reParse,
            cancelToken: archiveDownloadInfo.cancelToken,
            parser: ArchiveBotResponseParser.commonParse,
          ),
          retryIf: (e) => e is DioException && e.type != DioExceptionType.cancel,
          onRetry: (e) => log.download(
            'Parse archive download url: ${archive.title} failed, retry. Reason: ${(e as DioException).message}',
            level: Level.warning,
          ),
          maxAttempts: _maxRetryTimes,
        );
        log.download(
          'Parse archive download url via bot, response: $response',
          level: Level.info,
        );

        if (response.isSuccess) {
          ArchiveResolveVO archiveResolveVO = ArchiveResolveVO.fromResponse(response.data);
          downloadPath = archiveResolveVO.url;
        } else {
          snack('archiveError'.tr, response.errorMessage);
          return pauseDownloadArchive(archive.gid);
        }
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) {
          return;
        }

        return await _getDownloadUrl(archive);
      } catch (e) {
        log.download('Parse archive download url error, reason: $e', level: Level.error);
        snack('archiveError'.tr, e.toString(), isShort: true);
        return pauseDownloadArchive(archive.gid);
      }
    }

    if (archiveDownloadInfo.cancelToken.isCancelled) {
      return;
    }

    /// add start=1
    Uri uri = Uri.parse(downloadPath);
    Map<String, String> queryParameters = Map.from(uri.queryParameters);
    queryParameters.remove('autostart');
    queryParameters.putIfAbsent('start', () => '1');
    Uri replacedUri = uri.replace(queryParameters: queryParameters);
    downloadPath = replacedUri.toString();

    /// the bot protocol only returns the original archive url; the resample variant lives at the same path with trailing '/2' replaced by '/3'
    if (archiveDownloadInfo.parseSource != ArchiveParseSource.official.code &&
        !archive.isOriginal) {
      List<String> segments = List.of(replacedUri.pathSegments);
      if (segments.isNotEmpty && segments.last == '2') {
        segments[segments.length - 1] = '3';
        downloadPath = replacedUri.replace(pathSegments: segments).toString();
      } else {
        log.warning(
          'Bot returned archive url without trailing /2 segment, fallback to original: $downloadPath',
        );
      }
    }

    if (archiveDownloadInfo.parseSource == ArchiveParseSource.official.code) {
      archiveDownloadInfo.downloadUrl =
          Uri.parse(archiveDownloadInfo.downloadPageUrl!).resolve(downloadPath).toString();
    } else {
      archiveDownloadInfo.downloadUrl = downloadPath;
    }
    archiveDownloadInfo.forceReparse = false;

    log.trace(
      'Parse archive download url success: ${archive.title}, original: ${archive.isOriginal}, url: ${archiveDownloadInfo.downloadUrl}',
    );
    return _updateArchiveStatus(archive.gid, ArchiveStatus.parsedDownloadUrl);
  }

  Future<void> _doDownloadArchiveViaMultiIsolate(ArchiveDownloadedData archive) async {
    final ArchiveDownloadInfo? info = archiveDownloadInfos[archive.gid];
    if (info == null ||
        info.downloadCompleter != null ||
        !_isTaskInStatus(archive.gid, [
          ArchiveStatus.parsedDownloadUrl,
          ArchiveStatus.downloading,
        ])) {
      return;
    }
    final CancelToken session = info.cancelToken;
    if (session.isCancelled) {
      return;
    }
    final JDownloadTask task =
        info.downloadTask ??= _generateDownloadTask(info.downloadUrl!, archive);
    // Listen before startup: very short downloads can finish before start returns.
    final Completer<void> completion = Completer<void>();
    info.downloadCompleter = completion;
    completion.future.ignore();
    void clearCompletion() {
      if (identical(info.downloadCompleter, completion)) {
        info.downloadCompleter = null;
      }
    }

    try {
      await _updateArchiveStatus(archive.gid, ArchiveStatus.downloading);
      if (session.isCancelled) {
        return;
      }
      info.speedComputer
        ..resetDownloadedBytes(task.currentBytes)
        ..start();
      if (task.status != TaskStatus.completed) {
        await task.start();
        if (session.isCancelled) {
          return;
        }
        if (task.status == TaskStatus.completed && !completion.isCompleted) {
          completion.complete();
        }
        await completion.future;
      }
      if (session.isCancelled || !identical(archiveDownloadInfos[archive.gid], info)) {
        return;
      }
      info.speedComputer.dispose();
      await _updateArchiveStatus(archive.gid, ArchiveStatus.downloaded);
      unawaited(_tryWakeWaitingTasks());
    } on CancelException {
      return;
    } catch (error) {
      if (session.isCancelled) {
        return;
      }
      clearCompletion();
      final Object? cause = error is JDownloadException ? error.error : error;
      final int? statusCode = cause is DioException ? cause.response?.statusCode : null;
      if (statusCode == 410) {
        return await _check410Reason(info.downloadUrl!, archive);
      }
      log.download(
          'Download archive failed: ${archive.title}, original: ${archive.isOriginal}, reason: $error',
          level: Level.error);
      snack(
          'archiveError'.tr,
          switch (statusCode) {
            404 => '${'archiveLinkExpiredHint'.tr}\n${archive.title}',
            429 => '429Hints'.tr,
            _ => error.toString(),
          },
          isShort: statusCode != 404);
      await pauseDownloadArchive(archive.gid, needReUnlock: statusCode == 404);
    } finally {
      clearCompletion();
    }
  }

  Future<void> _unpackingArchive(ArchiveDownloadedData archive) async {
    ArchiveDownloadInfo archiveDownloadInfo = archiveDownloadInfos[archive.gid]!;
    if (!_isTaskInStatus(archive.gid, [ArchiveStatus.downloaded, ArchiveStatus.unpacking])) {
      return;
    }

    log.info('Unpacking archive: ${archive.title}, original: ${archive.isOriginal}');

    bool success = await extractZipArchive(
      computePackingFileDownloadPath(archive),
      computeArchiveUnpackingPath(archive.title, archive.gid),
    );

    if (!success) {
      log.error('Unpacking archive error!');
      log.uploadError(Exception('Unpacking error!'), extraInfos: {'archive': archive});
      snack(
        'unpackingArchiveError'.tr,
        '${'failedToDealWith'.tr}:${archive.title}',
        isShort: true,
      );

      archiveDownloadInfo.archiveStatus = ArchiveStatus.downloading;
      await archiveDownloadInfo.downloadTask!.dispose();
      archiveDownloadInfo.downloadTask = null;
      await _deletePackingFileInDisk(archive);
      _notifyDownloadActivityChanged();
      return pauseDownloadArchive(archive.gid);
    }

    if (downloadSetting.deleteArchiveFileAfterDownload.isTrue) {
      _deletePackingFileInDisk(archive);
    }

    await _saveArchiveInfoInDisk(archive);

    await _updateArchiveStatus(archive.gid, ArchiveStatus.completed);

    unawaited(_tryAutoMitigateArchiveToDownload(archive.gid));

    _tryWakeWaitingTasks();
  }

  // ALL

  Future<void> _instantiateFromDB() async {
    allGroups = (await ArchiveGroupDao.selectArchiveGroups()).map((e) => e.groupName).toList();
    log.debug('init Archive groups: $allGroups');

    List<ArchiveDownloadedData> archives = await ArchiveDao.selectArchives();

    for (ArchiveDownloadedData archive in archives) {
      _initArchiveInMemory(archive, sort: false);
    }
    _sortArchives();
  }

  Future<bool> _initArchiveInfo(ArchiveDownloadedData archive) async {
    if (!await _saveArchiveAndGroupInDatabase(archive)) {
      return false;
    }
    _initArchiveInMemory(archive);
    return true;
  }

  Future<bool> _addGroup(String group) async {
    if (!allGroups.contains(group)) {
      allGroups.add(group);
    }

    return (await ArchiveGroupDao.insertArchiveGroup(
          ArchiveGroupData(groupName: group, sortOrder: 0),
        ) >
        0);
  }

  // DB

  Future<bool> _saveArchiveAndGroupInDatabase(ArchiveDownloadedData archive) async {
    return appDb.transaction(() async {
      await ArchiveGroupDao.insertArchiveGroup(
        ArchiveGroupData(groupName: archive.groupName, sortOrder: 0),
      );

      return await ArchiveDao.insertArchive(
            ArchiveDownloadedCompanion.insert(
              gid: Value(archive.gid),
              token: archive.token,
              title: archive.title,
              category: archive.category,
              pageCount: archive.pageCount,
              galleryUrl: archive.galleryUrl,
              coverUrl: archive.coverUrl,
              uploader: Value(archive.uploader),
              size: archive.size,
              publishTime: archive.publishTime,
              archiveStatusCode: archive.archiveStatusCode,
              archivePageUrl: archive.archivePageUrl,
              downloadPageUrl: const Value(null),
              downloadUrl: const Value(null),
              sortOrder: Value(archive.sortOrder),
              groupName: archive.groupName,
              isOriginal: archive.isOriginal,
              insertTime: archive.insertTime,
              tags: Value(archive.tags),
              tagRefreshTime: Value(archive.tagRefreshTime),
              parseSource: Value(archive.parseSource),
            ),
          ) >
          0;
    });
  }

  Future<bool> _updateArchiveInDatabase(int gid) async {
    ArchiveDownloadInfo archiveDownloadInfo = archiveDownloadInfos[gid]!;

    return await ArchiveDao.updateArchive(
          ArchiveDownloadedCompanion(
            gid: Value(gid),
            archiveStatusCode: Value(archiveDownloadInfo.archiveStatus.code),
            downloadPageUrl: Value(archiveDownloadInfo.downloadPageUrl),
            downloadUrl: Value(archiveDownloadInfo.downloadUrl),
            size: Value(archiveDownloadInfo.size),
            sortOrder: Value(archiveDownloadInfo.sortOrder),
            groupName: Value(archiveDownloadInfo.group),
          ),
        ) >
        0;
  }

  Future<bool> _deleteArchiveInfoInDatabase(int gid) async {
    return await ArchiveDao.deleteArchive(gid) > 0;
  }

  // MEMORY

  void _initArchiveInMemory(ArchiveDownloadedData archive, {bool sort = true}) {
    if (!allGroups.contains(archive.groupName)) {
      allGroups.add(archive.groupName);
    }
    archives.add(archive);

    archiveDownloadInfos[archive.gid] = ArchiveDownloadInfo(
      size: archive.size,
      parseSource: archive.parseSource,
      downloadPageUrl: archive.downloadPageUrl,
      downloadUrl: archive.downloadUrl,
      archiveStatus: ArchiveStatus.fromCode(archive.archiveStatusCode),
      cancelToken: CancelToken(),
      speedComputer: SpeedComputer(
        updateCallback: () =>
            update(['$archiveSpeedComputerId::${archive.gid}::${archive.isOriginal}']),
      ),
      sortOrder: archive.sortOrder,
      group: archive.groupName,
    );

    if (archive.downloadUrl != null) {
      JDownloadTask downloadTask = archiveDownloadInfos[archive.gid]!.downloadTask =
          _generateDownloadTask(archive.downloadUrl!, archive);
      archiveDownloadInfos[archive.gid]!.speedComputer.resetDownloadedBytes(
            downloadTask.currentBytes,
          );
    }

    if (sort) {
      _sortArchives();
    }
    update([galleryCountChangedId, '$archiveStatusId::${archive.gid}']);

    _notifyDownloadActivityChanged();
  }

  Future<void> _deleteArchiveInMemory(int gid) async {
    archives.removeWhere((a) => a.gid == gid);
    ArchiveDownloadInfo? archiveDownloadInfo = archiveDownloadInfos.remove(gid);

    archiveDownloadInfo?.cancelToken.cancel();
    archiveDownloadInfo?.speedComputer.dispose();
    await archiveDownloadInfo?.downloadTask?.dispose();

    update([galleryCountChangedId]);

    _notifyDownloadActivityChanged();
  }

  // DISK

  Future<void> _saveArchiveInfoInDisk(ArchiveDownloadedData archive) async {
    File file = File(
      join(computeArchiveUnpackingPath(archive.title, archive.gid), metadataFileName),
    );
    if (!await file.exists()) {
      await file.create(recursive: true);
    }

    await file.writeAsString(jsonEncode(archive.toJson()));
  }

  Future<void> _deletePackingFileInDisk(ArchiveDownloadedData archive) async {
    File file = File(computePackingFileDownloadPath(archive));
    if (await file.exists()) {
      await file.delete();
    }
    return;
  }

  Future<void> _deleteArchiveInDisk(ArchiveDownloadedData archive) async {
    await _deletePackingFileInDisk(archive);

    final Directory directory = Directory(
      computeArchiveUnpackingPath(archive.title, archive.gid),
    );
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> _ensureDownloadDirExists() async {
    try {
      await Directory(downloadSetting.downloadPath.value).create(recursive: true);
    } on Exception catch (e) {
      log.error('Create download directory failed', e);
    }
  }
}

class ArchiveDownloadInfo {
  /// Archive true size is different from which displayed in detail page
  int size;

  int parseSource;

  String? downloadPageUrl;

  String? downloadUrl;

  ArchiveStatus archiveStatus;

  CancelToken cancelToken;

  JDownloadTask? downloadTask;

  Completer? downloadCompleter;

  bool forceReparse = false;

  SpeedComputer speedComputer;

  int sortOrder;

  String group;

  ArchiveDownloadInfo({
    required this.size,
    required this.parseSource,
    this.downloadPageUrl,
    this.downloadUrl,
    required this.archiveStatus,
    required this.cancelToken,
    this.downloadTask,
    this.downloadCompleter,
    required this.speedComputer,
    required this.sortOrder,
    required this.group,
  });

  @override
  String toString() {
    return 'ArchiveDownloadInfo{size: $size, parseSource: $parseSource, downloadPageUrl: $downloadPageUrl, downloadUrl: $downloadUrl, archiveStatus: $archiveStatus, cancelToken: $cancelToken, downloadTask: $downloadTask, downloadCompleter: $downloadCompleter, speedComputer: $speedComputer, sortOrder: $sortOrder, group: $group}';
  }
}

enum ArchiveStatus {
  needReUnlock(10),
  paused(20),
  unlocking(30),
  unlocked(35),
  parsingDownloadPageUrl(40),
  parsedDownloadPageUrl(45),
  parsingDownloadUrl(50),
  parsedDownloadUrl(55),
  waitingIsolate(58),
  downloading(60),
  downloaded(70),
  unpacking(80),
  completed(90);

  final int code;

  const ArchiveStatus(this.code);

  factory ArchiveStatus.fromCode(int code) {
    return ArchiveStatus.values.firstWhere((s) => s.code == code);
  }
}

enum OldArchiveStatus {
  none,
  needReUnlock,
  paused,
  unlocking,
  parsingDownloadPageUrl,
  parsingDownloadUrl,
  downloading,
  downloaded,
  unpacking,
  completed,
}

enum ArchiveParseSource {
  official(0),
  bot(1);

  final int code;

  const ArchiveParseSource(this.code);

  factory ArchiveParseSource.fromCode(int code) {
    return ArchiveParseSource.values.firstWhere((s) => s.code == code);
  }
}

enum _ArchiveMitigationOutcome { migrated, replaced, keptOriginal, skipped, failed }

class _MitigationInterruptedException implements Exception {
  const _MitigationInterruptedException();
}
