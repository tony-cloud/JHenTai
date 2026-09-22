import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/database/database.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/model/gallery_url.dart';
import 'package:jhentai/model/jh_layout.dart';
import 'package:jhentai/pages/details/details_page.dart';
import 'package:jhentai/pages/details/details_page_logic.dart';
import 'package:jhentai/pages/download/download_base_page.dart';
import 'package:jhentai/pages/download/grid/gallery/gallery_grid_download_page.dart';
import 'package:jhentai/pages/download/list/archive/archive_list_download_page.dart';
import 'package:jhentai/pages/download/list/archive/archive_list_download_page_logic.dart';
import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/service/archive_download_service.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/local_config_service.dart';
import 'package:jhentai/service/super_resolution_service.dart';
import 'package:jhentai/setting/style_setting.dart';
import 'package:jhentai/utils/speed_computer.dart';
import 'package:jhentai/widget/icon_text_button.dart';

class _LocalConfig extends LocalConfigService {
  @override
  Future<String?> read({required ConfigEnum configKey, String subConfigKey = ''}) async =>
      configKey == ConfigEnum.downloadPageBodyType ? '1' : null;

  @override
  Future<int> write(
          {required ConfigEnum configKey,
          String subConfigKey = '',
          required String value}) async =>
      1;
}

class _ArchiveService extends ArchiveDownloadService {
  @override
  void onClose() {}
}

class _DetailsLogic extends DetailsPageLogic {
  // Supply the detail state directly without starting online page requests.
  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  void onReady() {}

  @override
  void onClose() {}

  @override
  Future<int> getReadIndexRecord() async => 0;
}

void main() {
  final previousConfig = localConfigService;
  final previousArchive = archiveDownloadService;
  final previousStyle = styleSetting;

  setUp(() {
    Get.testMode = true;
    localConfigService = _LocalConfig();
    styleSetting = StyleSetting()..actualLayout = LayoutMode.mobile;
    archiveDownloadService = _ArchiveService()..allGroups = ['default', 'saved'];
    for (int gid = 1; gid <= 30; gid++) {
      final String group = gid <= 10 ? 'default' : 'saved';
      archiveDownloadService.archives.add(ArchiveDownloadedData(
        gid: gid,
        token: 'token',
        title: 'Archive $gid',
        category: 'Manga',
        pageCount: 1,
        galleryUrl: 'https://e-hentai.org/g/$gid/0123456789/',
        coverUrl: '',
        size: 32768,
        publishTime: '2026-09-22 00:00',
        archiveStatusCode: ArchiveStatus.paused.code,
        archivePageUrl: '',
        isOriginal: true,
        insertTime: '2026-09-22 00:00:00',
        sortOrder: gid,
        groupName: group,
        tags: '',
        parseSource: 1,
      ));
      archiveDownloadService.archiveDownloadInfos[gid] = ArchiveDownloadInfo(
        size: 32768,
        parseSource: 1,
        archiveStatus: ArchiveStatus.paused,
        cancelToken: CancelToken(),
        speedComputer: SpeedComputer(updateCallback: () {}),
        sortOrder: gid,
        group: group,
      );
    }
    Get.put<ArchiveDownloadService>(archiveDownloadService);
    Get.put<GalleryDownloadService>(galleryDownloadService);
    Get.put<SuperResolutionService>(superResolutionService);
  });

  tearDown(() async {
    for (final info in archiveDownloadService.archiveDownloadInfos.values) {
      info.speedComputer.dispose();
    }
    Get.reset();
    DownloadPageFocusBridge.setPendingArgument(null);
    localConfigService = previousConfig;
    archiveDownloadService = previousArchive;
    styleSetting = previousStyle;
  });

  Future<void> settleFocus(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('archive long press selects archives, expands the group and reveals the item',
      (tester) async {
    final logic = _DetailsLogic();
    logic.state.galleryUrl = GalleryUrl.parse('https://e-hentai.org/g/28/0123456789/');
    final details = DetailsPage.preview()
      ..logic = logic
      ..state = logic.state;
    await tester.pumpWidget(GetMaterialApp(
      home: Scaffold(
          body: Builder(
              builder: (context) =>
                  CustomScrollView(slivers: [details.buildActions(context)]))),
      getPages: [GetPage(name: Routes.download, page: () => const DownloadPage())],
    ));
    await tester.pump();
    final archiveButton = find.byWidgetPredicate((widget) =>
        widget is IconTextButton && widget.icon.icon == Icons.play_circle_outline);
    expect(archiveButton, findsOneWidget);
    await tester.longPress(archiveButton);
    await settleFocus(tester);
    final state = Get.find<ArchiveListDownloadPageLogic>().state;
    expect(find.byType(ArchiveListDownloadPage), findsOneWidget);
    expect(state.displayGroups, contains('saved'));
    expect(state.highlightedGid, 28);
    expect(state.scrollController.offset, greaterThan(0));
    expect(find.text('Archive 28').hitTestable(), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(state.highlightedGid, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an already mounted download tab accepts another archive focus request',
      (tester) async {
    styleSetting.actualLayout = LayoutMode.desktop;
    await tester.pumpWidget(const GetMaterialApp(home: DownloadPage()));
    await tester.pump();
    expect(find.byType(GalleryGridDownloadPage), findsOneWidget);
    DownloadPageFocusBridge.setPendingArgument(
        const DownloadPageArgument(targetArchiveGid: 1));
    await settleFocus(tester);
    final logic = Get.find<ArchiveListDownloadPageLogic>();
    expect(logic.state.highlightedGid, 1);
    DownloadPageFocusBridge.setPendingArgument(
        const DownloadPageArgument(targetArchiveGid: 28));
    await settleFocus(tester);
    expect(logic.state.highlightedGid, 28);
    expect(logic.state.displayGroups, contains('saved'));
    expect(find.text('Archive 28').hitTestable(), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox());
  });
}
