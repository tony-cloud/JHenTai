import 'package:jhentai/model/search_config.dart';
import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/pages/base/base_page_state.dart';
import 'package:jhentai/pages/base/multi_select/multi_select_gallery_state_mixin.dart';

class WatchedPageState extends BasePageState with MultiSelectGalleryStateMixin {
  WatchedPageState() {
    searchConfig = SearchConfig(searchType: SearchType.watched);
  }

  @override
  String get route => Routes.watched;
}
