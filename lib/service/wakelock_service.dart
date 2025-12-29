import 'dart:async';

import 'package:get/get.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';

WakelockService wakelockService = WakelockService();

class WakelockService extends GetxService
    with JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  final Map<String, _WakelockEntry> _locks = <String, _WakelockEntry>{};
  Future<void> _serialTask = Future<void>.value();
  bool _wakelockEnabledByService = false;

  List<String> get activeLocks => List<String>.unmodifiable(_locks.keys);

  bool isHeld(String name) => _locks.containsKey(name);

  bool get hasAny => _locks.isNotEmpty;

  @override
  Future<void> doInitBean() async {
    Get.put<WakelockService>(this, permanent: true);
  }

  @override
  Future<void> doAfterBeanReady() async {}

  Future<void> acquire(String name, {Duration? timeout}) {
    return _enqueue(() async {
      final _WakelockEntry entry =
          _locks.putIfAbsent(name, () => _WakelockEntry(name: name, timeout: timeout));
      if (timeout != null) {
        entry.timeout = timeout;
      }
      _armTimer(entry);
      await _syncWakelock();
    });
  }

  Future<void> release(String name) {
    return _enqueue(() async {
      final _WakelockEntry? entry = _locks.remove(name);
      entry?.dispose();
      await _syncWakelock();
    });
  }

  Future<void> resetTimer(String name, {Duration? timeout}) {
    return _enqueue(() async {
      final _WakelockEntry entry =
          _locks.putIfAbsent(name, () => _WakelockEntry(name: name, timeout: timeout));
      if (timeout != null) {
        entry.timeout = timeout;
      }
      _armTimer(entry);
    });
  }

  Future<void> _enqueue(Future<void> Function() action) {
    _serialTask = _serialTask.then((_) => action()).catchError((Object error, StackTrace stack) {
      log.error('Wakelock task failed', error, stack);
    });
    return _serialTask;
  }

  void _armTimer(_WakelockEntry entry) {
    entry.timer?.cancel();

    final Duration? timeout = entry.timeout;
    if (timeout == null) {
      entry.timer = null;
      return;
    }

    final int version = entry.bumpVersion();
    entry.timer = Timer(timeout, () => _handleTimerExpired(entry.name, version));
  }

  void _handleTimerExpired(String name, int version) {
    _enqueue(() async {
      final _WakelockEntry? entry = _locks[name];
      if (entry == null || entry.version != version) {
        return;
      }

      _locks.remove(name);
      entry.dispose();
      log.info('Wakelock expired for $name');
      await _syncWakelock();
    });
  }

  Future<void> _syncWakelock() async {
    final bool shouldKeepAwake = _locks.isNotEmpty;

    if (shouldKeepAwake) {
      if (_wakelockEnabledByService) {
        return;
      }
      try {
        final bool alreadyEnabled = await WakelockPlus.enabled;
        if (!alreadyEnabled) {
          await WakelockPlus.enable();
        }
        _wakelockEnabledByService = true;
      } on Exception catch (e, stack) {
        log.error('Enable wakelock failed', e, stack);
      }
      return;
    }

    if (_wakelockEnabledByService) {
      try {
        await WakelockPlus.disable();
      } on Exception catch (e, stack) {
        log.error('Disable wakelock failed', e, stack);
      }
      _wakelockEnabledByService = false;
    }
  }

  @override
  void onClose() {
    for (final _WakelockEntry entry in _locks.values) {
      entry.dispose();
    }
    _locks.clear();
    super.onClose();
  }
}

class _WakelockEntry {
  _WakelockEntry({required this.name, this.timeout});

  final String name;
  Duration? timeout;
  Timer? timer;
  int version = 0;

  int bumpVersion() => ++version;

  void dispose() {
    timer?.cancel();
    timer = null;
  }
}
