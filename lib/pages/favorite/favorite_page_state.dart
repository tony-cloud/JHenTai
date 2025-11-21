import 'package:jhentai/routes/routes.dart';

import '../../model/search_config.dart';
import '../base/base_page_state.dart';
import '../base/multi_select/multi_select_gallery_state_mixin.dart';

class FavoritePageState extends BasePageState with MultiSelectGalleryStateMixin {
  FavoritePageState() {
    searchConfig = SearchConfig(searchType: SearchType.favorite);
  }

  @override
  String get route => Routes.favorite;
}
