import 'dart:collection';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/model/jh_layout.dart';
import 'package:jhentai/service/local_config_service.dart';
import 'package:jhentai/utils/screen_size_util.dart';
import 'package:throttling/throttling.dart';
import 'package:window_manager/window_manager.dart';

import 'package:jhentai/setting/preference_setting.dart';
import 'package:jhentai/service/app_update_service.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/log.dart';

WindowService windowService = WindowService();

class WindowService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  static const double defaultLeftColumnWidthRatio = 1 - 0.618;

  /// Keep desktop split readable on web for legacy values migrated from
  /// different ratio semantics.
  static const double minWebDesktopLeftColumnWidthRatio = 0.3;

  bool windowManagerInited = false;

  double windowWidth = 1280;
  double windowHeight = 720;
  bool isMaximized = false;
  bool isFullScreen = false;

  double desktopLeftColumnWidthRatio = defaultLeftColumnWidthRatio;
  double tabletLeftColumnWidthRatio = defaultLeftColumnWidthRatio;

  final Debouncing windowResizedDebouncing =
      Debouncing(duration: const Duration(milliseconds: 300));
  final Debouncing columnResizedDebouncing =
      Debouncing(duration: const Duration(milliseconds: 300));

  @override
  List<JHLifeCircleBean> get initDependencies =>
      super.initDependencies..addAll([localConfigService, preferenceSetting, appUpdateService]);

  @override
  Future<void> doInitBean() async {
    windowWidth = await localConfigService
        .read(configKey: ConfigEnum.windowWidth)
        .then((value) => value != null ? double.parse(value) : windowWidth);
    windowHeight = await localConfigService
        .read(configKey: ConfigEnum.windowHeight)
        .then((value) => value != null ? double.parse(value) : windowHeight);
    isMaximized = await localConfigService
        .read(configKey: ConfigEnum.windowMaximize)
        .then((value) => value != null ? value == 'true' : isMaximized);
    isFullScreen = await localConfigService
        .read(configKey: ConfigEnum.windowFullScreen)
        .then((value) => value != null ? value == 'true' : isFullScreen);
    final double? legacyLeftColumnWidthRatio = _tryParseDouble(
      await localConfigService.read(configKey: ConfigEnum.leftColumnWidthRatio),
    );

    desktopLeftColumnWidthRatio = _normalizeDesktopLeftColumnWidthRatio(
      _tryParseDouble(
            await localConfigService.read(
              configKey: ConfigEnum.desktopLeftColumnWidthRatio,
            ),
          ) ??
          legacyLeftColumnWidthRatio ??
          desktopLeftColumnWidthRatio,
    );

    tabletLeftColumnWidthRatio = _normalizeLeftColumnWidthRatio(
      _tryParseDouble(
            await localConfigService.read(
              configKey: ConfigEnum.tabletLeftColumnWidthRatio,
            ),
          ) ??
          legacyLeftColumnWidthRatio ??
          tabletLeftColumnWidthRatio,
    );

    if (GetPlatform.isDesktop) {
      await windowManager.ensureInitialized();

      WindowOptions windowOptions = WindowOptions(
        center: true,
        size: Size(windowWidth, windowHeight),
        backgroundColor: Colors.transparent,
        skipTaskbar: false,
        title: 'JHenTai',
        titleBarStyle: GetPlatform.isWindows ? TitleBarStyle.hidden : TitleBarStyle.normal,
      );

      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
        if (preferenceSetting.launchInFullScreen.isTrue) {
          await windowManager.setFullScreen(true);
        }
        if (isMaximized) {
          await windowManager.maximize();
        }
        windowManagerInited = true;
      });
    }
  }

  @override
  Future<void> doAfterBeanReady() async {}

  double leftColumnWidthRatioForLayout(LayoutMode layoutMode) {
    if (layoutMode == LayoutMode.desktop) {
      return desktopLeftColumnWidthRatio;
    }

    return tabletLeftColumnWidthRatio;
  }

  void handleDoubleColumnResized(
    UnmodifiableListView<double> ratios,
    LayoutMode layoutMode,
  ) {
    if (ratios.isEmpty) {
      return;
    }

    final double currentRatio = leftColumnWidthRatioForLayout(layoutMode);
    if (currentRatio == ratios[0]) {
      return;
    }

    columnResizedDebouncing.debounce(() {
      final double normalizedRatio = layoutMode == LayoutMode.desktop
          ? _normalizeDesktopLeftColumnWidthRatio(ratios[0])
          : _normalizeLeftColumnWidthRatio(ratios[0]);

      if (layoutMode == LayoutMode.desktop) {
        desktopLeftColumnWidthRatio = normalizedRatio;
      } else {
        tabletLeftColumnWidthRatio = normalizedRatio;
      }

      log.info('Resize ${layoutMode.name} left column ratio to: $normalizedRatio');
      localConfigService.write(
        configKey: layoutMode == LayoutMode.desktop
            ? ConfigEnum.desktopLeftColumnWidthRatio
            : ConfigEnum.tabletLeftColumnWidthRatio,
        value: normalizedRatio.toString(),
      );
    });
  }

  double _normalizeLeftColumnWidthRatio(double ratio) {
    return max(0.01, ratio);
  }

  double _normalizeDesktopLeftColumnWidthRatio(double ratio) {
    double normalized = _normalizeLeftColumnWidthRatio(ratio);

    if (GetPlatform.isWeb) {
      normalized = max(minWebDesktopLeftColumnWidthRatio, normalized);
    }

    return normalized;
  }

  double? _tryParseDouble(String? value) {
    if (value == null) {
      return null;
    }

    return double.tryParse(value);
  }

  void handleWindowResized() {
    windowResizedDebouncing.debounce(() {
      windowWidth = fullScreenWidth;
      windowHeight = screenHeight;

      log.info('Resize window to: $windowWidth x $windowHeight');

      localConfigService.write(configKey: ConfigEnum.windowWidth, value: windowWidth.toString());
      localConfigService.write(configKey: ConfigEnum.windowHeight, value: windowHeight.toString());
    });
  }

  Future<int> saveMaximizeWindow(bool isMaximized) {
    log.info(isMaximized ? 'Maximized window' : 'Restored window');

    this.isMaximized = isMaximized;
    return localConfigService.write(
        configKey: ConfigEnum.windowMaximize, value: isMaximized.toString());
  }

  Future<int> saveFullScreen(bool isFullScreen) {
    log.info(isFullScreen ? 'Enter full screen' : 'Leave full screen');

    this.isFullScreen = isFullScreen;
    return localConfigService.write(
        configKey: ConfigEnum.windowFullScreen, value: isFullScreen.toString());
  }
}
