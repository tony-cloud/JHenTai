import '../../../routes/routes.dart';
import '../../base/base_page_state.dart';
import '../../base/multi_select/multi_select_gallery_state_mixin.dart';
import '../mixin/search_page_state_mixin.dart';

class DesktopSearchPageTabState extends BasePageState
    with SearchPageStateMixin, MultiSelectGalleryStateMixin {
  @override
  String get route => Routes.desktopSearch;
}
