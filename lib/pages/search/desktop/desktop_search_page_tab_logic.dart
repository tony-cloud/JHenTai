import 'dart:convert';

import 'package:jhentai/pages/search/desktop/desktop_search_page_tab_state.dart';
import 'package:jhentai/pages/search/mixin/new_search_argument.dart';

import '../../../enum/config_enum.dart';
import '../../../model/search_config.dart';
import '../../../service/local_config_service.dart';
import '../../../setting/preference_setting.dart';
import '../../base/base_page_logic.dart';
import '../../base/multi_select/multi_select_gallery_logic_mixin.dart';
import '../../base/multi_select/multi_select_gallery_state_mixin.dart';
import '../mixin/search_page_logic_mixin.dart';

class DesktopSearchPageTabLogic extends BasePageLogic
    with SearchPageLogicMixin, MultiSelectGalleryLogicMixin {
  final NewSearchArgument newSearchArgument;
  final bool loadImmediately;

  @override
  final DesktopSearchPageTabState state = DesktopSearchPageTabState();

  DesktopSearchPageTabLogic(this.newSearchArgument, this.loadImmediately);

  @override
  MultiSelectGalleryStateMixin get multiSelectGalleryState => state;

  @override
  Future<void> onReady() async {
    await state.searchConfigInitCompleter.future;

    String? keyword = newSearchArgument.keyword;
    SearchBehaviour searchBehaviour =
        newSearchArgument.keywordSearchBehaviour ?? preferenceSetting.searchBehaviour.value;
    SearchConfig? rewriteSearchConfig = newSearchArgument.rewriteSearchConfig;

    if (rewriteSearchConfig != null) {
      state.searchConfig = rewriteSearchConfig.copyWith();
    } else if (searchBehaviour == SearchBehaviour.inheritAll) {
      state.searchConfig.keyword = keyword;
    } else if (searchBehaviour == SearchBehaviour.inheritPartially) {
      state.searchConfig.keyword = keyword;
      state.searchConfig.language = null;
      state.searchConfig.enableAllCategories();
    } else if (searchBehaviour == SearchBehaviour.none) {
      state.searchConfig = SearchConfig(keyword: keyword);
    }

    if (loadImmediately) {
      handleClearAndRefresh();
    }
  }

  @override
  Future<void> saveSearchConfig(SearchConfig searchConfig) async {
    await localConfigService.write(
      configKey: ConfigEnum.searchConfig,
      subConfigKey: searchConfigKey,
      value: jsonEncode(searchConfig.copyWith(keyword: '', tags: [])),
    );
  }

  @override
  void toggleBodyType() {
    if (multiSelectGalleryState.inMultiSelectMode) {
      exitSelectMode();
    }
    super.toggleBodyType();
  }
}
