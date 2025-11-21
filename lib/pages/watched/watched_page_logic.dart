import 'dart:convert';

import 'package:jhentai/pages/watched/watched_page_state.dart';

import '../../enum/config_enum.dart';
import '../../model/search_config.dart';
import '../../service/local_config_service.dart';
import '../base/base_page_logic.dart';
import '../base/multi_select/multi_select_gallery_logic_mixin.dart';
import '../base/multi_select/multi_select_gallery_state_mixin.dart';

class WatchedPageLogic extends BasePageLogic with MultiSelectGalleryLogicMixin {
  @override
  bool get useSearchConfig => true;

  @override
  bool get autoLoadNeedLogin => true;

  @override
  final WatchedPageState state = WatchedPageState();

  @override
  MultiSelectGalleryStateMixin get multiSelectGalleryState => state;

  @override
  Future<void> saveSearchConfig(SearchConfig searchConfig) async {
    await localConfigService.write(
      configKey: ConfigEnum.searchConfig,
      subConfigKey: searchConfigKey,
      value: jsonEncode(searchConfig.copyWith(keyword: '', tags: [])),
    );
  }
}
