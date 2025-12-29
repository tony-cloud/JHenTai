import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/pages/watched/watched_page_state.dart';

import 'package:jhentai/pages/base/base_page.dart';
import 'package:jhentai/pages/watched/watched_page_logic.dart';

class WatchedPage extends BasePage {
  const WatchedPage({
    super.key,
    super.showMenuButton,
    super.showTitle,
    super.name,
  }) : super(
          showJumpButton: true,
          showFilterButton: true,
          showScroll2TopButton: true,
        );

  @override
  WatchedPageLogic get logic => Get.put<WatchedPageLogic>(WatchedPageLogic(), permanent: true);

  @override
  WatchedPageState get state => Get.find<WatchedPageLogic>().state;

  @override
  Widget? buildBottomNavigationBar(BuildContext context) {
    return logic.buildMultiSelectBottomBar(context);
  }
}
