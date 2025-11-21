import '../base/base_page_logic.dart';
import '../base/multi_select/multi_select_gallery_logic_mixin.dart';
import '../base/multi_select/multi_select_gallery_state_mixin.dart';
import 'popular_page_state.dart';

class PopularPageLogic extends BasePageLogic with MultiSelectGalleryLogicMixin {
  @override
  final PopularPageState state = PopularPageState();

  @override
  bool get useSearchConfig => false;

  @override
  MultiSelectGalleryStateMixin get multiSelectGalleryState => state;
}
