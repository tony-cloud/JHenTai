import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/pages/base/base_page_state.dart';
import 'package:jhentai/pages/base/multi_select/multi_select_gallery_state_mixin.dart';
import 'package:jhentai/pages/search/mixin/search_page_state_mixin.dart';

class SearchPageMobileV2State extends BasePageState
    with SearchPageStateMixin, MultiSelectGalleryStateMixin {
  @override
  String get route => Routes.mobileV2Search;
}
