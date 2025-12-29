import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/pages/gallerys/dashboard/simple/simple_dashboard_page_logic.dart';
import 'package:jhentai/pages/gallerys/dashboard/simple/simple_dashboard_page_state.dart';

import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/utils/route_util.dart';
import 'package:jhentai/pages/base/base_page.dart';
import 'package:jhentai/pages/layout/mobile_v2/mobile_layout_page_v2_state.dart';

/// For mobile v2 layout
class SimpleDashboardPage extends BasePage {
  const SimpleDashboardPage({super.key})
      : super(
          showMenuButton: true,
          showTitle: true,
          showScroll2TopButton: true,
        );

  @override
  String get name => 'home'.tr;

  @override
  SimpleDashboardPageLogic get logic =>
      Get.put<SimpleDashboardPageLogic>(SimpleDashboardPageLogic(), permanent: true);

  @override
  SimpleDashboardPageState get state => Get.find<SimpleDashboardPageLogic>().state;

  @override
  List<Widget> buildAppBarActions() {
    return [
      IconButton(icon: const Icon(Icons.settings), onPressed: logic.handleTapFilterButton),
      IconButton(icon: const Icon(Icons.search), onPressed: () => toRoute(Routes.mobileV2Search)),
      IconButton(
          icon: const Icon(Icons.more_vert),
          onPressed: MobileLayoutPageV2State.scaffoldKey.currentState?.openEndDrawer),
    ];
  }
}
