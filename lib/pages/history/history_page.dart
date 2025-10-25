import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../base/base_page.dart';
import 'history_page_logic.dart';
import 'history_page_state.dart';

class HistoryPage extends BasePage {
  const HistoryPage({
    super.key,
    super.showMenuButton,
    super.showTitle,
    super.name,
  }) : super(
          showJumpButton: true,
          showScroll2TopButton: true,
        );

  @override
  HistoryPageLogic get logic => Get.put<HistoryPageLogic>(HistoryPageLogic(), permanent: true);

  @override
  HistoryPageState get state => Get.find<HistoryPageLogic>().state;

  @override
  List<Widget> buildAppBarActions() {
    return [
      IconButton(
          icon: const Icon(Icons.delete_outline_outlined, size: 27),
          onPressed: logic.handleTapDeleteButton),
      ...super.buildAppBarActions(),
    ];
  }
}
