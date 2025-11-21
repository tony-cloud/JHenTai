import '../../model/search_config.dart';
import '../../routes/routes.dart';
import '../base/base_page_state.dart';
import '../base/multi_select/multi_select_gallery_state_mixin.dart';

class WatchedPageState extends BasePageState with MultiSelectGalleryStateMixin {
  WatchedPageState() {
    searchConfig = SearchConfig(searchType: SearchType.watched);
  }

  @override
  String get route => Routes.watched;
}
