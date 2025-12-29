import 'package:jhentai/routes/routes.dart';

import 'package:jhentai/model/search_config.dart';
import 'package:jhentai/pages/base/base_page_state.dart';
import 'package:jhentai/pages/base/multi_select/multi_select_gallery_state_mixin.dart';

class FavoritePageState extends BasePageState with MultiSelectGalleryStateMixin {
  FavoritePageState() {
    searchConfig = SearchConfig(searchType: SearchType.favorite);
  }

  @override
  String get route => Routes.favorite;
}
