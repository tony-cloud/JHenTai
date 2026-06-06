import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';

import 'package:jhentai/pages/base/base_page.dart';
import 'package:jhentai/pages/favorite/favorite_page_logic.dart';
import 'package:jhentai/pages/favorite/favorite_page_state.dart';

enum _FavoritePageMenuAction {
  downloadAndUpdateAll,
}

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
            icon: const FaIcon(FontAwesomeIcons.paperPlane, size: 20),
            onPressed: logic.handleTapJumpButton),
      if (state.gallerys.isNotEmpty)
        IconButton(icon: const Icon(Icons.sort), onPressed: logic.handleChangeSortOrder),
      PopupMenuButton<_FavoritePageMenuAction>(
        onSelected: (_FavoritePageMenuAction action) {
          switch (action) {
            case _FavoritePageMenuAction.downloadAndUpdateAll:
              logic.handleDownloadAndUpdateAllCurrentFavcat();
          }
        },
        itemBuilder: (BuildContext context) => <PopupMenuEntry<_FavoritePageMenuAction>>[
          PopupMenuItem<_FavoritePageMenuAction>(
            value: _FavoritePageMenuAction.downloadAndUpdateAll,
            child: Text('downloadAndUpdateAllCurrentFavcat'.tr),
          ),
        ],
      ),
      IconButton(
          icon: const Icon(Icons.filter_alt_outlined, size: 28),
          onPressed: logic.handleTapFilterButton),
    ];
  }
}
