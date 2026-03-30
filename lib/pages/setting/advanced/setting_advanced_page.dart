import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:extended_image/extended_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/extension/widget_extension.dart';
import 'package:jhentai/model/config.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/service/archive_download_service.dart';
import 'package:jhentai/service/cloud_service.dart';
import 'package:jhentai/setting/advanced_setting.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/path_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/service/read_progress_service.dart';
import 'package:jhentai/service/schedule_service.dart';
import 'package:jhentai/utils/toast_util.dart';
import 'package:logger/logger.dart';
import 'package:jhentai/widget/loading_state_indicator.dart';
import 'package:path/path.dart';
import 'package:jhentai/service/ftp_server_service.dart';
import 'package:jhentai/setting/ftp_server_setting.dart';
import 'package:flutter_fd_utils/flutter_fd_utils.dart';

import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/enum/config_type_enum.dart';
import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/service/isolate_service.dart';
import 'package:jhentai/utils/byte_util.dart';
import 'package:jhentai/utils/route_util.dart';
import 'package:jhentai/widget/eh_config_type_select_dialog.dart';
import 'package:jhentai/pages/setting/advanced/ftp_server_dialog.dart';

class SettingAdvancedPage extends StatefulWidget {
  const SettingAdvancedPage({super.key});

  @override
  State<SettingAdvancedPage> createState() => _SettingAdvancedPageState();
}

class _SettingAdvancedPageState extends State<SettingAdvancedPage> {
  LoadingState _logLoadingState = LoadingState.idle;
  String _logSize = '...';

  LoadingState _imageCacheLoadingState = LoadingState.idle;
  String _imageCacheSize = '...';

  LoadingState _exportDataLoadingState = LoadingState.idle;
  LoadingState _importDataLoadingState = LoadingState.idle;
  LoadingState _refreshGalleryTagsState = LoadingState.idle;
  LoadingState _refreshArchiveTagsState = LoadingState.idle;
  LoadingState _mitigateArchiveToDownloadState = LoadingState.idle;
  LoadingState _repairMissingImagesState = LoadingState.idle;
  LoadingState _cleanupDuplicatedGalleryState = LoadingState.idle;
  LoadingState _clearParentGalleryCacheState = LoadingState.idle;

  late final TextEditingController _historySearchLimitController;

  @override
  void initState() {
    super.initState();

    _loadingLogSize();
    _getImagesCacheSize();

    _historySearchLimitController = TextEditingController(
      text: _formatHistoryLimitText(advancedSetting.historySearchLimit.value),
    );
  }

  @override
  void dispose() {
    _historySearchLimitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(centerTitle: true, title: Text('advancedSetting'.tr)),
      body: Obx(
        () => ListView(
          padding: const EdgeInsets.only(top: 16),
          children: [
            _buildEnableLogging(),
            if (advancedSetting.enableLogging.isTrue) _buildRecordAllLogs().fadeInWidget(),
            if (advancedSetting.enableLogging.isTrue) _buildLogLevel().fadeInWidget(),
            _buildOpenLogs(),
            _buildClearLogs(context),
            _buildFdDebugReport(context),
            _buildClearImageCache(context),
            _buildClearNetworkCache(),
            _buildClearReadProgress(),
            _buildRepairMissingImages(context),
            _buildCleanupDuplicatedGallery(context),
            _buildClearParentGalleryCache(context),
            _buildRpcSettings(),
            _buildFtpServer(context),
            if (GetPlatform.isDesktop) _buildSuperResolution(),
            _buildCheckUpdate(),
            _buildRefreshGalleryTags(),
            _buildRefreshArchiveTags(),
            _buildAutoMitigateArchiveToDownload(),
            _buildMitigateArchiveToDownload(context),
            _buildHistorySearchLimit(),
            _buildCheckClipboard(),
            if (GetPlatform.isAndroid) _buildVerifyAppLinks(),
            _buildInNoImageMode(),
            _buildImportData(context),
            _buildExportData(context),
          ],
        ).withListTileTheme(context),
      ),
    );
  }

  Widget _buildEnableLogging() {
    return ListTile(
      title: Text('enableLogging'.tr),
      subtitle: Text('needRestart'.tr),
      trailing: Switch(
          value: advancedSetting.enableLogging.value, onChanged: advancedSetting.saveEnableLogging),
    );
  }

  Widget _buildRecordAllLogs() {
    return SwitchListTile(
      title: Text('enableVerboseLogging'.tr),
      subtitle: Text('needRestart'.tr),
      value: advancedSetting.enableVerboseLogging.value,
      onChanged: advancedSetting.saveEnableVerboseLogging,
    );
  }

  static const List<Level> _logLevels = [
    Level.trace,
    Level.debug,
    Level.info,
    Level.warning,
    Level.error,
  ];

  Widget _buildLogLevel() {
    return ListTile(
      title: Text('logLevel'.tr),
      subtitle: Text('logLevelHint'.tr),
      trailing: DropdownButton<Level>(
        value: advancedSetting.logLevel.value,
        onChanged: (Level? level) {
          if (level == null) {
            return;
          }
          advancedSetting.saveLogLevel(level);
        },
        items: _logLevels
            .map((level) => DropdownMenuItem<Level>(
                  value: level,
                  child: Text(level.name.toUpperCase()),
                ))
            .toList(),
      ),
    );
  }

  Widget _buildOpenLogs() {
    return ListTile(
      title: Text('openLog'.tr),
      trailing: const Icon(Icons.keyboard_arrow_right).marginOnly(right: 4),
      onTap: () => toRoute(Routes.logList),
    );
  }

  Widget _buildClearLogs(BuildContext context) {
    return ListTile(
      title: Text('clearLogs'.tr),
      subtitle: Text('longPress2Clear'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LoadingStateIndicator(
            loadingState: _logLoadingState,
            useCupertinoIndicator: true,
            successWidgetBuilder: () => Text(
              _logSize,
              style: TextStyle(
                  color: UIConfig.resumePauseButtonColor(context), fontWeight: FontWeight.w500),
            ),
            errorTapCallback: _loadingLogSize,
          ).marginOnly(right: 8)
        ],
      ),
      onLongPress: _clearAndLoadingLogSize,
    );
  }

  Widget _buildFdDebugReport(BuildContext context) {
    return ListTile(
      title: Text('fdDebugReport'.tr),
      subtitle: Text('fdDebugReportHint'.tr),
      trailing: const Icon(Icons.keyboard_arrow_right).marginOnly(right: 4),
      onTap: () => FdReportDialog.show(context),
    );
  }

  Widget _buildClearImageCache(BuildContext context) {
    return ListTile(
      title: Text('clearImagesCache'.tr),
      subtitle: Text('longPress2Clear'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LoadingStateIndicator(
            loadingState: _imageCacheLoadingState,
            useCupertinoIndicator: true,
            successWidgetBuilder: () => Text(
              _imageCacheSize,
              style: TextStyle(
                  color: UIConfig.resumePauseButtonColor(context), fontWeight: FontWeight.w500),
            ),
            errorTapCallback: _getImagesCacheSize,
          ).marginOnly(right: 8)
        ],
      ),
      onLongPress: _clearAndLoadingImageCacheSize,
    );
  }

  Widget _buildClearNetworkCache() {
    return ListTile(
      title: Text('clearPageCache'.tr),
      subtitle: Text('longPress2Clear'.tr),
      onLongPress: () async {
        await ehRequest.removeAllCache();
        toast('clearSuccess'.tr, isCenter: false);
      },
    );
  }

  Widget _buildClearReadProgress() {
    return ListTile(
      title: Text('clearReadProgress'.tr),
      subtitle: Text('longPress2Clear'.tr),
      onLongPress: () async {
        try {
          await readProgressService.clearAllProgress();
          toast('clearSuccess'.tr, isCenter: false);
        } on Exception catch (e, s) {
          log.error('Clear read progress failed', e, s);
          toast('internalError'.tr);
        }
      },
    );
  }

  Widget _buildRepairMissingImages(BuildContext context) {
    final BuildContext tileContext = context;

    return ListTile(
      title: Text('repairMissingImages'.tr),
      subtitle: Text('repairMissingImagesHint'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LoadingStateIndicator(
            loadingState: _repairMissingImagesState,
            useCupertinoIndicator: true,
            idleWidgetBuilder: () =>
                Icon(Icons.refresh, color: UIConfig.resumePauseButtonColor(tileContext)),
            successWidgetBuilder: () =>
                Icon(Icons.check, color: UIConfig.resumePauseButtonColor(tileContext)),
            errorWidgetBuilder: () => Icon(
              Icons.error_outline,
              color: Theme.of(tileContext).colorScheme.error,
            ),
            errorTapCallback: _repairMissingImages,
          ).marginOnly(right: 8)
        ],
      ),
      onLongPress: _repairMissingImages,
    );
  }

  Widget _buildCleanupDuplicatedGallery(BuildContext context) {
    final BuildContext tileContext = context;

    return ListTile(
      title: Text('cleanupDuplicatedGallery'.tr),
      subtitle: Text('cleanupDuplicatedGalleryHint'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LoadingStateIndicator(
            loadingState: _cleanupDuplicatedGalleryState,
            useCupertinoIndicator: true,
            idleWidgetBuilder: () =>
                Icon(Icons.cleaning_services, color: UIConfig.resumePauseButtonColor(tileContext)),
            successWidgetBuilder: () =>
                Icon(Icons.check, color: UIConfig.resumePauseButtonColor(tileContext)),
            errorWidgetBuilder: () => Icon(
              Icons.error_outline,
              color: Theme.of(tileContext).colorScheme.error,
            ),
            errorTapCallback: _cleanupDuplicatedGallery,
          ).marginOnly(right: 8)
        ],
      ),
      onLongPress: _cleanupDuplicatedGallery,
    );
  }

  Widget _buildClearParentGalleryCache(BuildContext context) {
    final BuildContext tileContext = context;

    return ListTile(
      title: Text('clearParentGalleryCache'.tr),
      subtitle: Text('clearParentGalleryCacheHint'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LoadingStateIndicator(
            loadingState: _clearParentGalleryCacheState,
            useCupertinoIndicator: true,
            idleWidgetBuilder: () =>
                Icon(Icons.delete_sweep, color: UIConfig.resumePauseButtonColor(tileContext)),
            successWidgetBuilder: () =>
                Icon(Icons.check, color: UIConfig.resumePauseButtonColor(tileContext)),
            errorWidgetBuilder: () => Icon(
              Icons.error_outline,
              color: Theme.of(tileContext).colorScheme.error,
            ),
            errorTapCallback: _clearParentGalleryCache,
          ).marginOnly(right: 8)
        ],
      ),
      onLongPress: _clearParentGalleryCache,
    );
  }

  Widget _buildFtpServer(BuildContext context) {
    final bool enabled = ftpServerSetting.enableServer.value;
    final bool running = ftpServerService.serverRunning.value;
    final String summary = enabled
        ? 'ftpServerRunningSummary'
            .tr
            .replaceAll('@port', ftpServerSetting.port.value.toString())
            .replaceAll(
                '@access',
                ftpServerSetting.allowReadAndWrite.isTrue
                    ? 'ftpServerAccessReadWrite'.tr
                    : 'ftpServerAccessReadOnly'.tr)
        : 'ftpServerDisabledSummary'.tr;

    return ListTile(
      title: Text('ftpServer'.tr),
      subtitle: Text(summary),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (running)
            Icon(Icons.wifi_tethering, color: UIConfig.resumePauseButtonColor(context))
                .marginOnly(right: 8),
          const Icon(Icons.keyboard_arrow_right).marginOnly(right: 4),
        ],
      ),
      onTap: () => _showFtpServerDialog(context),
    );
  }

  Widget _buildRpcSettings() {
    return ListTile(
      title: Text('rpcSettings'.tr),
      subtitle: Text('rpcSettingsHint'.tr),
      trailing: const Icon(Icons.keyboard_arrow_right).marginOnly(right: 4),
      onTap: () => toRoute(Routes.settingRpcServer),
    );
  }

  Widget _buildSuperResolution() {
    return ListTile(
      title: Text('superResolution'.tr),
      trailing: const Icon(Icons.keyboard_arrow_right).marginOnly(right: 4),
      onTap: () => toRoute(Routes.superResolution),
    );
  }

  Future<void> _showFtpServerDialog(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (_) => const FtpServerDialog(),
    );
  }

  Widget _buildCheckUpdate() {
    return SwitchListTile(
      title: Text('checkUpdateAfterLaunchingApp'.tr),
      value: advancedSetting.enableCheckUpdate.value,
      onChanged: advancedSetting.saveEnableCheckUpdate,
    );
  }

  Widget _buildRefreshGalleryTags() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: _refreshGalleryTagsManually,
      child: SwitchListTile(
        title: Text('refreshGalleryTagsAutomatically'.tr),
        subtitle: Text('longPress2Refresh'.tr),
        value: advancedSetting.enableRefreshGalleryTags.value,
        onChanged: advancedSetting.saveEnableRefreshGalleryTags,
        secondary: Builder(
          builder: (tileContext) => _buildManualRefreshIndicator(
            tileContext,
            _refreshGalleryTagsState,
            _refreshGalleryTagsManually,
          ),
        ),
      ),
    );
  }

  Widget _buildRefreshArchiveTags() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: _refreshArchiveTagsManually,
      child: SwitchListTile(
        title: Text('refreshArchiveTagsAutomatically'.tr),
        subtitle: Text('longPress2Refresh'.tr),
        value: advancedSetting.enableRefreshArchiveTags.value,
        onChanged: advancedSetting.saveEnableRefreshArchiveTags,
        secondary: Builder(
          builder: (tileContext) => _buildManualRefreshIndicator(
            tileContext,
            _refreshArchiveTagsState,
            _refreshArchiveTagsManually,
          ),
        ),
      ),
    );
  }

  Widget _buildCheckClipboard() {
    return SwitchListTile(
      title: Text('checkClipboard'.tr),
      value: advancedSetting.enableCheckClipboard.value,
      onChanged: advancedSetting.saveEnableCheckClipboard,
    );
  }

  Widget _buildAutoMitigateArchiveToDownload() {
    return SwitchListTile(
      title: Text('autoMitigateArchiveToDownloadAfterComplete'.tr),
      subtitle: Text('autoMitigateArchiveToDownloadAfterCompleteHint'.tr),
      value: advancedSetting.enableAutoMitigateArchiveToDownload.value,
      onChanged: advancedSetting.saveEnableAutoMitigateArchiveToDownload,
    );
  }

  Widget _buildMitigateArchiveToDownload(BuildContext context) {
    final BuildContext tileContext = context;
    final bool showInterruptButton = _mitigateArchiveToDownloadState == LoadingState.loading;

    return ListTile(
      title: Text('mitigateArchiveToDownload'.tr),
      subtitle: Text('mitigateArchiveToDownloadHint'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LoadingStateIndicator(
            loadingState: _mitigateArchiveToDownloadState,
            useCupertinoIndicator: true,
            idleWidgetBuilder: () =>
                Icon(Icons.sync, color: UIConfig.resumePauseButtonColor(tileContext)),
            successWidgetBuilder: () =>
                Icon(Icons.check, color: UIConfig.resumePauseButtonColor(tileContext)),
            errorWidgetBuilder: () => Icon(
              Icons.error_outline,
              color: Theme.of(tileContext).colorScheme.error,
            ),
            errorTapCallback: _mitigateArchiveToDownloadManually,
          ).marginOnly(right: 8),
          if (showInterruptButton)
            IconButton(
              onPressed: _interruptArchiveMitigation,
              tooltip: 'stop'.tr,
              icon: Icon(
                Icons.stop_circle_outlined,
                color: UIConfig.alertColor(tileContext),
              ),
            ),
        ],
      ),
      onTap: _mitigateArchiveToDownloadManually,
    );
  }

  Widget _buildVerifyAppLinks() {
    return ListTile(
      title: Text('verityAppLinks4Android12'.tr),
      subtitle: Text('verityAppLinks4Android12Hint'.tr),
      trailing: const Icon(Icons.keyboard_arrow_right).marginOnly(right: 4),
      onTap: () async {
        try {
          await const AndroidIntent(
            action: 'android.settings.APP_OPEN_BY_DEFAULT_SETTINGS',
            data: 'package:top.jtmonster.jhentai',
          ).launch();
        } on Exception catch (e) {
          log.error(e);
          log.uploadError(e);
          toast('error'.tr);
        }
      },
    );
  }

  Widget _buildInNoImageMode() {
    return SwitchListTile(
      title: Text('noImageMode'.tr),
      value: advancedSetting.inNoImageMode.value,
      onChanged: advancedSetting.saveInNoImageMode,
    );
  }

  Widget _buildImportData(BuildContext context) {
    return ListTile(
      title: Text('importData'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LoadingStateIndicator(
            loadingState: _importDataLoadingState,
            idleWidgetBuilder: () => const Icon(Icons.keyboard_arrow_right),
            successWidgetSameWithIdle: true,
            useCupertinoIndicator: true,
            errorWidgetSameWithIdle: true,
          ).marginOnly(right: 8)
        ],
      ),
      onTap: () => _importData(context),
    );
  }

  Widget _buildExportData(BuildContext context) {
    return ListTile(
      title: Text('exportData'.tr),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          LoadingStateIndicator(
            loadingState: _exportDataLoadingState,
            idleWidgetBuilder: () => const Icon(Icons.keyboard_arrow_right),
            successWidgetSameWithIdle: true,
            useCupertinoIndicator: true,
            errorWidgetSameWithIdle: true,
          ).marginOnly(right: 8)
        ],
      ),
      onTap: () => _exportData(context),
    );
  }

  Future<void> _loadingLogSize() async {
    if (_logLoadingState == LoadingState.loading) {
      return;
    }

    setStateSafely(() => _logLoadingState = LoadingState.loading);

    try {
      _logSize = await log.getSize();
    } catch (e) {
      log.error('loading log size error', e);
      _logSize = '-1B';
      setStateSafely(() => _imageCacheLoadingState = LoadingState.error);
      return;
    }

    setStateSafely(() => _logLoadingState = LoadingState.success);
  }

  Future<void> _clearAndLoadingLogSize() async {
    if (_logLoadingState == LoadingState.loading) {
      return;
    }

    await log.clear();
    await _loadingLogSize();

    toast('clearSuccess'.tr, isCenter: false);
  }

  Future<void> _getImagesCacheSize() async {
    if (_imageCacheLoadingState == LoadingState.loading) {
      return;
    }

    setStateSafely(() => _imageCacheLoadingState = LoadingState.loading);

    try {
      _imageCacheSize = await compute(
        (dirPath) {
          Directory cacheImagesDirectory = Directory(dirPath);

          int totalBytes;
          if (!cacheImagesDirectory.existsSync()) {
            totalBytes = 0;
          } else {
            totalBytes = cacheImagesDirectory.listSync().fold<int>(
                0, (previousValue, element) => previousValue += (element as File).lengthSync());
          }

          return byte2String(totalBytes.toDouble());
        },
        join(pathService.tempDir.path, cacheImageFolderName),
      );
    } catch (e) {
      log.error(e);
      _imageCacheSize = '-1B';
      setStateSafely(() => _imageCacheLoadingState = LoadingState.error);
      return;
    }

    setStateSafely(() => _imageCacheLoadingState = LoadingState.success);
  }

  Future<void> _clearAndLoadingImageCacheSize() async {
    if (_imageCacheLoadingState == LoadingState.loading) {
      return;
    }

    await clearDiskCachedImages();
    await _getImagesCacheSize();

    toast('clearSuccess'.tr, isCenter: false);
  }

  Future<void> _repairMissingImages() async {
    if (_repairMissingImagesState == LoadingState.loading) {
      return;
    }

    setStateSafely(() => _repairMissingImagesState = LoadingState.loading);

    try {
      final result = await galleryDownloadService.repairMissingImagesForAllGalleries();
      if (!mounted) {
        return;
      }
      setStateSafely(() => _repairMissingImagesState = LoadingState.success);
      toast(
        'repairMissingImagesResult'
            .trParams({'count': '${result.repaired}', 'renamed': '${result.renamed}'}),
        isCenter: false,
      );
    } catch (e, s) {
      log.error('Repair missing images failed', e, s);
      if (mounted) {
        setStateSafely(() => _repairMissingImagesState = LoadingState.error);
        toast('internalError'.tr);
      }
    }

    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted || _repairMissingImagesState == LoadingState.loading) {
        return;
      }

      setStateSafely(() => _repairMissingImagesState = LoadingState.idle);
    });
  }

  Future<void> _cleanupDuplicatedGallery() async {
    if (_cleanupDuplicatedGalleryState == LoadingState.loading) {
      return;
    }

    if (galleryDownloadService.usesRemoteRpcData) {
      toast('cleanupDuplicatedGalleryUnavailableInRpcMode'.tr, isCenter: false);
      return;
    }

    setStateSafely(() => _cleanupDuplicatedGalleryState = LoadingState.loading);

    try {
      final result = await galleryDownloadService.cleanupDuplicatedGalleries();
      if (!mounted) {
        return;
      }

      setStateSafely(() => _cleanupDuplicatedGalleryState = LoadingState.success);
      toast(
        'cleanupDuplicatedGalleryResult'.trParams({
          'checked': '${result.checked}',
          'deleted': '${result.deleted}',
          'skipped': '${result.skipped}',
          'failed': '${result.failed}',
        }),
        isCenter: false,
      );
    } catch (e, s) {
      log.error('Cleanup duplicated gallery failed', e, s);
      if (mounted) {
        setStateSafely(() => _cleanupDuplicatedGalleryState = LoadingState.error);
        toast('internalError'.tr);
      }
    }

    _resetStateAfterDelay(
      loadingState: () => _cleanupDuplicatedGalleryState,
      reset: () => _cleanupDuplicatedGalleryState = LoadingState.idle,
    );
  }

  Future<void> _clearParentGalleryCache() async {
    if (_clearParentGalleryCacheState == LoadingState.loading) {
      return;
    }

    setStateSafely(() => _clearParentGalleryCacheState = LoadingState.loading);

    try {
      final int count = await galleryDownloadService.clearParentGalleryCache();
      if (!mounted) {
        return;
      }

      setStateSafely(() => _clearParentGalleryCacheState = LoadingState.success);
      toast(
        'clearParentGalleryCacheResult'.trParams({'count': '$count'}),
        isCenter: false,
      );
    } catch (e, s) {
      log.error('Clear parent gallery cache failed', e, s);
      if (mounted) {
        setStateSafely(() => _clearParentGalleryCacheState = LoadingState.error);
        toast('internalError'.tr);
      }
    }

    _resetStateAfterDelay(
      loadingState: () => _clearParentGalleryCacheState,
      reset: () => _clearParentGalleryCacheState = LoadingState.idle,
    );
  }

  void _resetStateAfterDelay({
    required LoadingState Function() loadingState,
    required VoidCallback reset,
  }) {
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted || loadingState() == LoadingState.loading) {
        return;
      }

      setStateSafely(reset);
    });
  }

  Future<void> _importData(BuildContext context) async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        compressionQuality: 100,
      );
    } on Exception catch (e) {
      log.error('Pick import data file failed', e);
      return;
    }

    if (result == null) {
      return;
    }

    if (_importDataLoadingState == LoadingState.loading) {
      return;
    }

    log.info('Import data from ${result.files.first.path}');
    setStateSafely(() => _importDataLoadingState = LoadingState.loading);

    File file = File(result.files.first.path!);
    String string = await file.readAsString();

    try {
      List list = await isolateService.jsonDecodeAsync(string);
      List<CloudConfig> configs = list.map((e) => CloudConfig.fromJson(e)).toList();
      for (CloudConfig config in configs) {
        await cloudConfigService.importConfig(config);
      }

      toast('success'.tr);
      setStateSafely(() => _importDataLoadingState = LoadingState.success);
    } catch (e, s) {
      log.error('Import data failed', e, s);
      toast('internalError'.tr);
      setStateSafely(() => _importDataLoadingState = LoadingState.error);
      return;
    }
  }

  Future<void> _exportData(BuildContext context) async {
    List<CloudConfigTypeEnum>? result = await showDialog(
      context: context,
      builder: (_) => EHConfigTypeSelectDialog(title: 'selectExportItems'.tr),
    );
    if (result?.isEmpty ?? true) {
      return;
    }

    String fileName =
        '${CloudConfigService.configFileName}-${DateFormat('yyyyMMddHHmmss').format(DateTime.now())}.json';
    if (GetPlatform.isMobile) {
      return _exportDataMobile(fileName, result);
    } else {
      return _exportDataDesktop(fileName, result);
    }
  }

  Future<void> _exportDataMobile(String fileName, List<CloudConfigTypeEnum>? result) async {
    if (_exportDataLoadingState == LoadingState.loading) {
      return;
    }
    setStateSafely(() => _exportDataLoadingState = LoadingState.loading);

    List<CloudConfig> uploadConfigs = [];
    for (CloudConfigTypeEnum type in result!) {
      CloudConfig? config = await cloudConfigService.getLocalConfig(type);
      if (config != null) {
        uploadConfigs.add(config);
      }
    }

    try {
      String? savedPath = await FilePicker.platform.saveFile(
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: utf8.encode(await isolateService.jsonEncodeAsync(uploadConfigs)),
        lockParentWindow: true,
      );
      if (savedPath != null) {
        log.info('Export data to $savedPath success');
        toast('success'.tr);
        setStateSafely(() => _exportDataLoadingState = LoadingState.success);
      }
    } on Exception catch (e) {
      log.error('Export data failed', e);
      toast('internalError'.tr);
      setStateSafely(() => _exportDataLoadingState = LoadingState.error);
    }
  }

  Future<void> _exportDataDesktop(String fileName, List<CloudConfigTypeEnum>? result) async {
    if (_exportDataLoadingState == LoadingState.loading) {
      return;
    }
    setStateSafely(() => _exportDataLoadingState = LoadingState.loading);

    String? savedPath;
    try {
      savedPath = await FilePicker.platform.saveFile(
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
        lockParentWindow: true,
      );
    } on Exception catch (e) {
      log.error('Select save path for exporting data failed', e);
      toast('internalError'.tr);
      setStateSafely(() => _exportDataLoadingState = LoadingState.error);
      return;
    }

    if (savedPath == null) {
      return;
    }

    List<CloudConfig> uploadConfigs = [];
    for (CloudConfigTypeEnum type in result!) {
      CloudConfig? config = await cloudConfigService.getLocalConfig(type);
      if (config != null) {
        uploadConfigs.add(config);
      }
    }

    File file = File(savedPath);
    try {
      if (await file.exists()) {
        await file.create(recursive: true);
      }
      await file.writeAsString(await isolateService.jsonEncodeAsync(uploadConfigs));
      log.info('Export data to $savedPath success');
      toast('success'.tr);
      setStateSafely(() => _exportDataLoadingState = LoadingState.success);
    } on Exception catch (e) {
      log.error('Export data failed', e);
      toast('internalError'.tr);
      setStateSafely(() => _exportDataLoadingState = LoadingState.error);
      file.delete().ignore();
    }
  }

  Widget _buildManualRefreshIndicator(
    BuildContext tileContext,
    LoadingState state,
    Future<void> Function() runTask,
  ) {
    final Color accent = UIConfig.resumePauseButtonColor(tileContext);
    return SizedBox(
      height: 24,
      width: 24,
      child: LoadingStateIndicator(
        height: 24,
        width: 24,
        loadingState: state,
        useCupertinoIndicator: true,
        indicatorRadius: 10,
        idleWidgetBuilder: () => Icon(Icons.refresh, color: accent, size: 20),
        successWidgetBuilder: () => Icon(Icons.check, color: accent, size: 20),
        errorWidgetBuilder: () =>
            Icon(Icons.error_outline, color: Theme.of(tileContext).colorScheme.error, size: 20),
        errorTapCallback: () {
          runTask();
        },
      ),
    );
  }

  Widget _buildHistorySearchLimit() {
    return ListTile(
      title: Text('historySearchLimit'.tr),
      subtitle: Text('historySearchLimitHint'.tr),
      trailing: SizedBox(
        width: 96,
        child: TextField(
          controller: _historySearchLimitController,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          textAlign: TextAlign.end,
          decoration: InputDecoration(
            hintText: '0',
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: _saveHistorySearchLimit,
        ),
      ),
    );
  }

  Future<void> _refreshGalleryTagsManually() async {
    if (_refreshGalleryTagsState == LoadingState.loading) {
      return;
    }

    setStateSafely(() => _refreshGalleryTagsState = LoadingState.loading);

    try {
      await scheduleService.refreshGalleryTags(ignoreSetting: true);
      setStateSafely(() => _refreshGalleryTagsState = LoadingState.success);
      toast('success'.tr, isCenter: false);
    } catch (e, s) {
      log.error('Manual refresh gallery tags failed', e, s);
      toast('internalError'.tr);
      setStateSafely(() => _refreshGalleryTagsState = LoadingState.error);
    }

    _resetManualRefreshStateAfterDelay(isGallery: true);
  }

  Future<void> _refreshArchiveTagsManually() async {
    if (_refreshArchiveTagsState == LoadingState.loading) {
      return;
    }

    setStateSafely(() => _refreshArchiveTagsState = LoadingState.loading);

    try {
      await scheduleService.refreshArchiveTags(ignoreSetting: true);
      setStateSafely(() => _refreshArchiveTagsState = LoadingState.success);
      toast('success'.tr, isCenter: false);
    } catch (e, s) {
      log.error('Manual refresh archive tags failed', e, s);
      toast('internalError'.tr);
      setStateSafely(() => _refreshArchiveTagsState = LoadingState.error);
    }

    _resetManualRefreshStateAfterDelay(isGallery: false);
  }

  Future<void> _mitigateArchiveToDownloadManually() async {
    if (_mitigateArchiveToDownloadState == LoadingState.loading) {
      return;
    }

    setStateSafely(() => _mitigateArchiveToDownloadState = LoadingState.loading);

    try {
      final ArchiveMitigationReport report =
          await archiveDownloadService.mitigateCompletedOriginalArchives();
      if (!mounted) {
        return;
      }

      setStateSafely(() => _mitigateArchiveToDownloadState = LoadingState.success);
      toast(
        'mitigateArchiveToDownloadResult'.trParams({
          'checked': '${report.checked}',
          'migrated': '${report.migrated}',
          'replaced': '${report.replaced}',
          'kept': '${report.keptOriginal}',
          'skipped': '${report.skipped}',
          'failed': '${report.failed}',
        }),
        isCenter: false,
      );
    } catch (e, s) {
      log.error('Manual archive mitigation failed', e, s);
      if (mounted) {
        setStateSafely(() => _mitigateArchiveToDownloadState = LoadingState.error);
        toast('internalError'.tr);
      }
    }

    _resetStateAfterDelay(
      loadingState: () => _mitigateArchiveToDownloadState,
      reset: () => _mitigateArchiveToDownloadState = LoadingState.idle,
    );
  }

  void _interruptArchiveMitigation() {
    if (archiveDownloadService.interruptMitigation()) {
      toast('stop'.tr, isCenter: false);
    }
  }

  void _resetManualRefreshStateAfterDelay({required bool isGallery}) {
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }

      final bool shouldSkip = isGallery
          ? _refreshGalleryTagsState == LoadingState.loading
          : _refreshArchiveTagsState == LoadingState.loading;
      if (shouldSkip) {
        return;
      }

      setStateSafely(() {
        if (isGallery) {
          _refreshGalleryTagsState = LoadingState.idle;
        } else {
          _refreshArchiveTagsState = LoadingState.idle;
        }
      });
    });
  }

  String _formatHistoryLimitText(int value) {
    return value <= 0 ? '' : value.toString();
  }

  void _saveHistorySearchLimit(String text) {
    final int? parsed = text.isEmpty ? 0 : int.tryParse(text);
    if (parsed == null) {
      _historySearchLimitController.text =
          _formatHistoryLimitText(advancedSetting.historySearchLimit.value);
      return;
    }

    advancedSetting.saveHistorySearchLimit(parsed);
    _historySearchLimitController.text = _formatHistoryLimitText(parsed);
  }
}
