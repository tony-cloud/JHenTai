import '../../model/search_config.dart';
import '../../routes/routes.dart';
import '../base/base_page_state.dart';
import '../base/multi_select/multi_select_gallery_state_mixin.dart';

class PopularPageState extends BasePageState with MultiSelectGalleryStateMixin {
  PopularPageState() {
    searchConfig = SearchConfig(searchType: SearchType.popular);
  }

  @override
  String get route => Routes.popular;
}
