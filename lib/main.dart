import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/network/jh_request.dart';
import 'package:jhentai/service/app_update_service.dart';
import 'package:jhentai/service/archive_download_service.dart';
import 'package:jhentai/service/built_in_blocked_user_service.dart';
import 'package:jhentai/service/cloud_service.dart';
import 'package:jhentai/service/frame_rate_service.dart';
import 'package:jhentai/service/ftp_server_service.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/history_service.dart';
import 'package:jhentai/service/doh_service.dart';
import 'package:jhentai/service/isolate_service.dart';
import 'package:jhentai/service/jh_service.dart';
import 'package:jhentai/service/image_block_service.dart';
import 'package:jhentai/service/local_block_rule_service.dart';
import 'package:jhentai/service/local_config_service.dart';
import 'package:jhentai/service/local_gallery_service.dart';
import 'package:jhentai/service/path_service.dart';
import 'package:jhentai/service/read_progress_service.dart';
import 'package:jhentai/service/quick_search_service.dart';
import 'package:jhentai/service/schedule_service.dart';
import 'package:jhentai/service/search_history_service.dart';
import 'package:jhentai/service/storage_service.dart';
import 'package:jhentai/service/super_resolution_service.dart';
import 'package:jhentai/service/tag_search_order_service.dart';
import 'package:jhentai/service/tag_translation_service.dart';
import 'package:jhentai/service/volume_service.dart';
import 'package:jhentai/service/windows_service.dart';
import 'package:jhentai/setting/advanced_setting.dart';
import 'package:jhentai/setting/archive_bot_setting.dart';
import 'package:jhentai/setting/download_setting.dart';
import 'package:jhentai/setting/eh_setting.dart';
import 'package:jhentai/setting/favorite_setting.dart';
import 'package:jhentai/setting/ftp_server_setting.dart';
import 'package:jhentai/setting/mouse_setting.dart';
import 'package:jhentai/setting/my_tags_setting.dart';
import 'package:jhentai/setting/network_setting.dart';
import 'package:jhentai/setting/performance_setting.dart';
import 'package:jhentai/setting/preference_setting.dart';
import 'package:jhentai/setting/read_setting.dart';
import 'package:jhentai/setting/site_setting.dart';
import 'package:jhentai/setting/super_resolution_setting.dart';
import 'package:jhentai/setting/user_setting.dart';
import 'package:jhentai/widget/app_manager.dart';
import 'package:jhentai/l18n/locale_text.dart';
import 'package:jhentai/routes/getx_router_observer.dart';
import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/setting/security_setting.dart';
import 'package:jhentai/setting/style_setting.dart';
import 'package:jhentai/service/log.dart';

import 'package:jhentai/config/theme_config.dart';
import 'package:jhentai/network/archive_bot_request.dart';
import 'package:jhentai/service/wakelock_service.dart';

List<JHLifeCircleBean> lifeCircleBeans = [
  dohService,
  ehRequest,
  jhRequest,
  archiveBotRequest,
  appUpdateService,
  galleryDownloadService,
  archiveDownloadService,
  wakelockService,
  localGalleryService,
  cloudConfigService,
  frameRateService,
  ftpServerService,
  historyService,
  isolateService,
  localBlockRuleService,
  imageBlockService,
  localConfigService,
  readProgressService,
  log,
  pathService,
  quickSearchService,
  scheduleService,
  searchHistoryService,
  storageService,
  superResolutionService,
  tagTranslationService,
  tagSearchOrderOptimizationService,
  volumeService,
  windowService,
  advancedSetting,
  downloadSetting,
  ftpServerSetting,
  archiveBotSetting,
  ehSetting,
  favoriteSetting,
  mouseSetting,
  myTagsSetting,
  networkSetting,
  performanceSetting,
  preferenceSetting,
  readSetting,
  securitySetting,
  siteSetting,
  styleSetting,
  superResolutionSetting,
  userSetting,
  builtInBlockedUserService,
];

void main(List<String> args) async {
  if (GetPlatform.isDesktop && runWebViewTitleBarWidget(args)) {
    return;
  }

  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    statusBarColor: Colors.transparent,
  ));

  lifeCircleBeans = topologicalSort(lifeCircleBeans);
  for (JHLifeCircleBean bean in lifeCircleBeans) {
    await bean.initBean();
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'JHenTai',
      themeMode: styleSetting.themeMode.value,
      theme: ThemeConfig.theme(styleSetting.lightThemeColor.value, Brightness.light),
      darkTheme: ThemeConfig.theme(styleSetting.darkThemeColor.value, Brightness.dark),

      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en', 'US'),
        Locale('zh', 'CN'),
        Locale('zh', 'TW'),
        Locale('ko', 'KR'),
        Locale('pt', 'BR'),
      ],
      locale: preferenceSetting.locale.value,
      fallbackLocale: const Locale('en', 'US'),
      translations: LocaleText(),

      getPages: Routes.pages,
      initialRoute:
          securitySetting.enablePasswordAuth.isTrue || securitySetting.enableBiometricAuth.isTrue
              ? Routes.lock
              : Routes.home,
      navigatorObservers: [GetXRouterObserver()],
      builder: (context, child) => AppManager(child: child!),

      /// enable swipe back feature
      popGesture: preferenceSetting.enableSwipeBackGesture.isTrue,
      onReady: () {
        for (JHLifeCircleBean bean in lifeCircleBeans) {
          bean.afterBeanReady();
        }
      },
    );
  }
}

List<JHLifeCircleBean> topologicalSort(List<JHLifeCircleBean> lifeCircleBeans) {
  // Maps to store the visiting state and result order
  final visiting = <JHLifeCircleBean, bool>{};
  final visited = <JHLifeCircleBean, bool>{};
  final result = <JHLifeCircleBean>[];

  // Helper function for DFS
  void visit(JHLifeCircleBean node) {
    if (visited.containsKey(node)) {
      return;
    }
    if (visiting[node] == true) {
      throw Exception('Circular dependency detected');
    }
    visiting[node] = true;
    for (final dependency in node.initDependencies) {
      visit(dependency);
    }
    visiting[node] = false;
    visited[node] = true;
    result.add(node);
  }

  // Visit all nodes
  for (final node in lifeCircleBeans) {
    visit(node);
  }

  return result.toList();
}
