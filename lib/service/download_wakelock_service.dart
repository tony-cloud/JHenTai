import 'package:get/get.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../setting/download_setting.dart';
import 'archive_download_service.dart';
import 'gallery_download_service.dart';
import 'jh_service.dart';
import 'log.dart';

DownloadWakelockService downloadWakelockService = DownloadWakelockService();

class DownloadWakelockService extends GetxService
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  final RxBool _galleryActive = false.obs;
  final RxBool _archiveActive = false.obs;

  Worker? _settingWorker;
  Future<void> _serialTask = Future.value();
  bool _wakelockEnabledByService = false;

  @override
  List<JHLifeCircleBean> get initDependencies =>
      [downloadSetting, galleryDownloadService, archiveDownloadService, log];

  Future<void> _enqueue(Future<void> Function() action) {
    _serialTask = _serialTask.then((_) => action()).catchError((error, stack) {
      log.error('Download wakelock task failed', error, stack);
    });
    return _serialTask;
  }

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
    _settingWorker = ever(downloadSetting.keepScreenOnWhileDownloading, (_) => _syncWakelock());
    await _syncWakelock();
  }

  @override
  Future<void> doAfterBeanReady() async {}

  void updateGalleryActive(bool active) {
    if (_galleryActive.value == active) {
      return;
    }
    _galleryActive.value = active;
    _syncWakelock(_galleryActive.value || _archiveActive.value);
  }

  void updateArchiveActive(bool active) {
    if (_archiveActive.value == active) {
      return;
    }
    _archiveActive.value = active;
    _syncWakelock(_galleryActive.value || _archiveActive.value);
  }

  Future<void> _syncWakelock([bool? forcedActive]) {
    return _enqueue(() async {
      // Preserve the activity snapshot that triggered this sync to avoid racing during fast copies.
      final bool isActive = forcedActive ?? (_galleryActive.value || _archiveActive.value);
      final bool shouldKeepAwake = downloadSetting.keepScreenOnWhileDownloading.isTrue && isActive;

      if (shouldKeepAwake) {
        try {
          final bool alreadyEnabled = await WakelockPlus.enabled;
          if (!alreadyEnabled) {
            await WakelockPlus.enable();
            _wakelockEnabledByService = true;
          }
        } on Exception catch (e, stack) {
          log.error('Enable wakelock for downloads failed', e, stack);
        }
        return;
      }

      if (_wakelockEnabledByService) {
        try {
          await WakelockPlus.disable();
        } on Exception catch (e, stack) {
          log.error('Disable wakelock for downloads failed', e, stack);
        }
        _wakelockEnabledByService = false;
      }
    });
  }

  @override
  void onClose() {
    _settingWorker?.dispose();
    super.onClose();
  }
}
