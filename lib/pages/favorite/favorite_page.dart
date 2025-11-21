import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';

import '../base/base_page.dart';
import 'favorite_page_logic.dart';
import 'favorite_page_state.dart';

class FavoritePage extends BasePage {
  const FavoritePage({
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
  FavoritePageLogic get logic => Get.put<FavoritePageLogic>(FavoritePageLogic(), permanent: true);

  @override
  FavoritePageState get state => Get.find<FavoritePageLogic>().state;

  @override
  Widget? buildBottomNavigationBar(BuildContext context) {
    return logic.buildMultiSelectBottomBar(context);
  }

  @override
  List<Widget> buildAppBarActions() {
    return [
      if (state.gallerys.isNotEmpty)
        IconButton(
            icon: const Icon(FontAwesomeIcons.paperPlane, size: 20),
            onPressed: logic.handleTapJumpButton),
      if (state.gallerys.isNotEmpty)
        IconButton(icon: const Icon(Icons.sort), onPressed: logic.handleChangeSortOrder),
      IconButton(
          icon: const Icon(Icons.filter_alt_outlined, size: 28),
          onPressed: logic.handleTapFilterButton),
    ];
  }
}
