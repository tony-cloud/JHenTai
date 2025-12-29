import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:blur/blur.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_windowmanager_plus/flutter_windowmanager_plus.dart';
import 'package:get/get.dart';
import 'package:jhentai/extension/get_logic_extension.dart';

import 'package:jhentai/config/theme_config.dart';
import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/setting/performance_setting.dart';
import 'package:jhentai/setting/security_setting.dart';
import 'package:jhentai/setting/style_setting.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/service/wakelock_service.dart';
import 'package:jhentai/utils/route_util.dart';

typedef DidChangePlatformBrightnessCallback = void Function();
typedef DidChangeAppLifecycleStateCallback = void Function(AppLifecycleState state);
typedef DidHaveMemoryPressureCallback = void Function();
typedef AppLaunchCallback = void Function(BuildContext context);

class AppManager extends StatefulWidget {
  static final List<DidChangePlatformBrightnessCallback> _didChangePlatformBrightnessCallbacks = [];
  static final List<DidChangeAppLifecycleStateCallback> _didChangeAppLifecycleStateCallbacks = [];
  static final List<DidHaveMemoryPressureCallback> _didHaveMemoryPressureCallbacks = [];

  static final List<AppLaunchCallback> _appLaunchCallbacks = [];

  final Widget child;

  const AppManager({super.key, required this.child});

  @override
  State<AppManager> createState() => _AppManagerState();

  static void registerDidChangePlatformBrightnessCallback(
      DidChangePlatformBrightnessCallback callback) {
    _didChangePlatformBrightnessCallbacks.add(callback);
  }

  static void unRegisterDidChangePlatformBrightnessCallback(
      DidChangePlatformBrightnessCallback callback) {
    _didChangePlatformBrightnessCallbacks.remove(callback);
  }

  static void registerDidHaveMemoryPressureCallback(DidHaveMemoryPressureCallback callback) {
    _didHaveMemoryPressureCallbacks.add(callback);
  }

  static void unRegisterDidHaveMemoryPressureCallback(DidHaveMemoryPressureCallback callback) {
    _didHaveMemoryPressureCallbacks.remove(callback);
  }

  static void registerAppLaunchCallback(AppLaunchCallback callback) {
    _appLaunchCallbacks.add(callback);
  }

  static void unRegisterAppLaunchCallback(AppLaunchCallback callback) {
    _appLaunchCallbacks.remove(callback);
  }
}

class _AppManagerState extends State<AppManager> with WidgetsBindingObserver {
  late final AppLifecycleListener _listener;
  DateTime? lastInactiveTime;
  bool inBlur = false;
  bool _inactivateShadeVisible = false;
  Alignment _shadeTextAlignment = Alignment.center;
  final Random _shadeRandom = Random();
  final Duration _shadeMoveInterval = const Duration(seconds: 3);
  final Duration _inactivateCheckInterval = const Duration(seconds: 1);
  Timer? _inactivateCheckTimer;
  Timer? _shadeMoveTimer;
  DateTime _lastUserInteraction = DateTime.now();

  late AppLifecycleState _currentState;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(log.markFirstFrameRendered());
    });

    _listener = AppLifecycleListener(
      onInactive: _onInactive,
      onResume: _onResume,
      onStateChange: (AppLifecycleState state) => _currentState = state,
    );

    _startInactivateWatcher();

    AppManager.registerAppLaunchCallback(_addSecureFlagForAndroid);
    AppManager.registerDidChangePlatformBrightnessCallback(_changeTheme);
    AppManager.registerDidHaveMemoryPressureCallback(_logMemoryPressure);

    for (var callback in AppManager._appLaunchCallbacks) {
      callback.call(context);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _listener.dispose();
    _inactivateCheckTimer?.cancel();
    _shadeMoveTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    AppManager.unRegisterAppLaunchCallback(_addSecureFlagForAndroid);
    AppManager.unRegisterDidChangePlatformBrightnessCallback(_changeTheme);
    AppManager.unRegisterDidHaveMemoryPressureCallback(_logMemoryPressure);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    for (DidChangePlatformBrightnessCallback callback
        in AppManager._didChangePlatformBrightnessCallbacks) {
      callback.call();
    }
    super.didChangePlatformBrightness();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    for (DidChangeAppLifecycleStateCallback callback
        in AppManager._didChangeAppLifecycleStateCallbacks) {
      callback.call(state);
    }
    super.didChangeAppLifecycleState(state);
  }

  @override
  void didHaveMemoryPressure() {
    if (_currentState == AppLifecycleState.resumed) {
      for (DidHaveMemoryPressureCallback callback in AppManager._didHaveMemoryPressureCallbacks) {
        callback.call();
      }
    }
    super.didHaveMemoryPressure();
  }

  @override
  Widget build(BuildContext context) {
    final Widget content = inBlur
        ? Blur(
            blur: 100,
            blurColor: GetPlatform.isAndroid ? Colors.white : Colors.grey.shade600,
            colorOpacity: 1,
            child: widget.child,
          )
        : widget.child;

    return ScrollConfiguration(
      behavior: UIConfig.scrollBehaviourWithScrollBar,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _markUserInteraction(),
        onPointerHover: (_) => _markUserInteraction(),
        onPointerMove: (_) => _markUserInteraction(),
        onPointerSignal: (_) => _markUserInteraction(),
        child: Stack(
          children: [
            content,
            if (_inactivateShadeVisible) _buildInactivateShade(),
          ],
        ),
      ),
    );
  }

  void _changeTheme() {
    if (styleSetting.themeMode.value != ThemeMode.system) {
      return;
    }
    if (PlatformDispatcher.instance.platformBrightness == Brightness.light) {
      Get.rootController.theme =
          ThemeConfig.theme(styleSetting.lightThemeColor.value, Brightness.light);
    } else {
      Get.rootController.darkTheme =
          ThemeConfig.theme(styleSetting.darkThemeColor.value, Brightness.dark);
    }

    Get.rootController.updateSafely();
  }

  void _logMemoryPressure() {
    log.warning('Memory pressure');
  }

  void _onInactive() {
    log.debug('App is hidden');

    _markUserInteraction();

    if (securitySetting.enableAuthOnResume.isTrue) {
      lastInactiveTime ??= DateTime.now();
    }

    if ((securitySetting.enableAuthOnResume.isTrue || securitySetting.enableBlur.isTrue) &&
        !inBlur &&
        !isRouteAtTop(Routes.lock)) {
      setState(() => inBlur = true);
    }
  }

  void _onResume() {
    log.debug('App is shown');

    _markUserInteraction();

    if (!inBlur) {
      return;
    }

    if (securitySetting.enableBlur.isFalse) {
      return;
    }

    if (securitySetting.enableAuthOnResume.isFalse) {
      setState(() => inBlur = false);
      return;
    }

    if ((securitySetting.enablePasswordAuth.isTrue || securitySetting.enableBiometricAuth.isTrue) &&
        DateTime.now().difference(lastInactiveTime!).inSeconds >= 3) {
      toRoute(Routes.lock);
      Future.delayed(const Duration(milliseconds: 300), () => setState(() => inBlur = false));
      lastInactiveTime = null;
    } else {
      setState(() => inBlur = false);
      return;
    }
  }

  /// for Android, blur is invalid when switch app to background(app is still clearly visible in switcher),
  /// so i choose to set FLAG_SECURE to do the same effect.
  void _addSecureFlagForAndroid(BuildContext context) {
    if (GetPlatform.isAndroid &&
        (securitySetting.enableAuthOnResume.isTrue || securitySetting.enableBlur.isTrue)) {
      FlutterWindowManagerPlus.addFlags(FlutterWindowManagerPlus.FLAG_SECURE);
    }
  }

  void _startInactivateWatcher() {
    _inactivateCheckTimer ??=
        Timer.periodic(_inactivateCheckInterval, (_) => _checkInactivateShade());
  }

  void _checkInactivateShade() {
    if (performanceSetting.enableInactivateShade.isFalse) {
      _hideInactivateShade();
      return;
    }

    final int timeoutSeconds = performanceSetting.inactivateTimeoutSeconds.value;
    if (timeoutSeconds <= 0) {
      _hideInactivateShade();
      return;
    }

    if (!wakelockService.hasAny) {
      _hideInactivateShade();
      return;
    }

    final Duration inactiveFor = DateTime.now().difference(_lastUserInteraction);
    if (inactiveFor.inSeconds < timeoutSeconds) {
      _hideInactivateShade();
      return;
    }

    _showInactivateShade();
  }

  void _markUserInteraction() {
    _lastUserInteraction = DateTime.now();
    _hideInactivateShade();
  }

  void _showInactivateShade() {
    if (_inactivateShadeVisible) {
      return;
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    setState(() => _inactivateShadeVisible = true);
    _shadeMoveTimer ??= Timer.periodic(_shadeMoveInterval, (_) {
      setState(() => _shadeTextAlignment = _nextShadeAlignment());
    });
  }

  void _hideInactivateShade() {
    if (!_inactivateShadeVisible) {
      return;
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    setState(() => _inactivateShadeVisible = false);
    _shadeMoveTimer?.cancel();
    _shadeMoveTimer = null;
  }

  Alignment _nextShadeAlignment() {
    const double min = -0.8;
    const double max = 0.8;
    return Alignment(
      min + (max - min) * _shadeRandom.nextDouble(),
      min + (max - min) * _shadeRandom.nextDouble(),
    );
  }

  Widget _buildInactivateShade() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _markUserInteraction,
        onPanDown: (_) => _markUserInteraction(),
        child: Container(
          color: Colors.black,
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 50),
            alignment: _shadeTextAlignment,
            child: Obx(
              () => Text(
                performanceSetting.inactivateShadeText.value,
                style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
