import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/service/path_service.dart';
import 'package:jhentai/service/wakelock_service.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

class _NativeWakelock extends WakelockPlusPlatformInterface {
  bool awake = false;
  bool failNextDisable = false;
  Completer<void>? enableGate;
  final List<bool> toggles = [];

  @override
  Future<bool> get enabled async => awake;

  @override
  Future<void> toggle({required bool enable}) async {
    toggles.add(enable);
    if (enable) {
      await enableGate?.future;
    }
    if (!enable && failNextDisable) {
      failNextDisable = false;
      throw PlatformException(code: 'temporary-disable-failure');
    }
    awake = enable;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WakelockPlusPlatformInterface previousPlatform;
  late _NativeWakelock native;
  late WakelockService service;
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('jhentai-wakelock-');
    pathService
      ..tempDir = directory
      ..appDocDir = directory;
  });

  tearDownAll(() async {
    await log.clear();
    await directory.delete(recursive: true);
  });

  setUp(() {
    previousPlatform = wakelockPlusPlatformInstance;
    native = _NativeWakelock();
    wakelockPlusPlatformInstance = native;
    service = WakelockService();
  });

  tearDown(() {
    wakelockPlusPlatformInstance = previousPlatform;
  });

  void timedTest(String description, Future<void> Function(WidgetTester) body) {
    testWidgets(description, (tester) async {
      service = WakelockService();
      try {
        await body(tester);
      } finally {
        service.onClose();
        await service.release('test-barrier');
      }
    });
  }

  test('only the last owner releases the native wakelock', () async {
    await service.acquire('reader');
    await service.acquire('download');
    await service.release('reader');
    expect(native.awake, isTrue);
    expect(service.activeLocks, ['download']);
    await service.release('download');
    expect(native.awake, isFalse);
    expect(native.toggles, [true, false]);
  });

  timedTest('failed native release is retried even with no more activity',
      (tester) async {
    await service.acquire('download');
    native.failNextDisable = true;
    await service.release('download');
    expect(service.hasAny, isFalse);
    expect(native.awake, isTrue);
    await tester.pump(const Duration(seconds: 5));
    expect(native.awake, isFalse);
    expect(native.toggles, [true, false, false]);
  });

  timedTest('release retry respects a new owner', (tester) async {
    await service.acquire('download');
    native.failNextDisable = true;
    await service.release('download');
    await service.acquire('reader');
    await tester.pump(const Duration(seconds: 5));
    expect(native.awake, isTrue);
    await service.release('reader');
    expect(native.awake, isFalse);
  });

  test(
      'closing releases the native lock and rejects queued or later acquisitions',
      () async {
    await service.acquire('reader');
    final Future<void> pending = service.acquire('download');
    service.onClose();
    await pending;
    await service.acquire('late-reader');
    await service.release('test-barrier');
    expect(service.hasAny, isFalse);
    expect(native.awake, isFalse);
  });

  timedTest('changing a timed lock to unlimited cancels its old deadline',
      (tester) async {
    await service.acquire('reader', timeout: const Duration(minutes: 5));
    await service.acquire('reader');
    await tester.pump(const Duration(minutes: 6));
    expect(service.isHeld('reader'), isTrue);
    expect(native.awake, isTrue);
    await service.release('reader');
  });

  timedTest('resetting an expired reader timer also restores the native lock',
      (tester) async {
    await service.acquire('reader', timeout: const Duration(minutes: 5));
    await tester.pump(const Duration(minutes: 5));
    expect(service.hasAny, isFalse);
    expect(native.awake, isFalse);
    await service.resetTimer('reader', timeout: const Duration(minutes: 10));
    expect(service.isHeld('reader'), isTrue);
    expect(native.awake, isTrue);
    await tester.pump(const Duration(minutes: 10));
    expect(service.hasAny, isFalse);
    expect(native.awake, isFalse);
  });

  timedTest('a queued expiry cannot release a reader changed to unlimited',
      (tester) async {
    native.enableGate = Completer<void>();
    final acquiring =
        service.acquire('reader', timeout: const Duration(minutes: 5));
    await tester.pump();
    final renewing = service.acquire('reader');
    await tester.pump(const Duration(minutes: 5));
    native.enableGate!.complete();
    await acquiring;
    await renewing;
    await service.release('test-barrier');
    expect(service.isHeld('reader'), isTrue);
    expect(native.awake, isTrue);
  });

  timedTest('closing during a native acquisition releases it once it finishes',
      (tester) async {
    native.enableGate = Completer<void>();
    final acquiring = service.acquire('reader');
    await tester.pump();
    service.onClose();
    native.enableGate!.complete();
    await acquiring;
    await service.release('test-barrier');
    expect(service.hasAny, isFalse);
    expect(native.awake, isFalse);
    expect(native.toggles, [true, false]);
  });
}
