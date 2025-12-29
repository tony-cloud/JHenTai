import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_navigation/get_navigation.dart';
import 'package:get/get_utils/get_utils.dart';
import 'package:jhentai/extension/get_logic_extension.dart';
import 'package:jhentai/model/gallery_page.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/widget/eh_favorite_sort_order_dialog.dart';

import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/exception/eh_site_exception.dart';
import 'package:jhentai/model/search_config.dart';
import 'package:jhentai/service/local_config_service.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/utils/snack_util.dart';
import 'package:jhentai/widget/loading_state_indicator.dart';
import 'package:jhentai/pages/base/base_page_logic.dart';
import 'package:jhentai/pages/base/multi_select/multi_select_gallery_logic_mixin.dart';
import 'package:jhentai/pages/base/multi_select/multi_select_gallery_state_mixin.dart';
import 'package:jhentai/pages/favorite/favorite_page_state.dart';

class FavoritePageLogic extends BasePageLogic with MultiSelectGalleryLogicMixin {
  @override
  bool get useSearchConfig => true;

  @override
  bool get autoLoadNeedLogin => true;

  @override
  final FavoritePageState state = FavoritePageState();

  @override
  @override
  MultiSelectGalleryStateMixin get multiSelectGalleryState => state;

  Future<void> handleChangeSortOrder() async {
    if (state.refreshState == LoadingState.loading) {
      return;
    }

    FavoriteSortOrder? result =
        await Get.dialog(EHFavoriteSortOrderDialog(init: state.favoriteSortOrder));
    if (result == null) {
      return;
    }

    if (state.refreshState == LoadingState.loading) {
      return;
    }

    state.loadingState = LoadingState.loading;

    state.gallerys.clear();
    state.prevGid = null;
    state.nextGid = null;
    state.seek = DateTime.now();
    state.totalCount = null;
    state.favoriteSortOrder = null;

    jump2Top();

    updateSafely();

    try {
      await ehRequest.requestChangeFavoriteSortOrder(result,
          parser: EHSpiderParser.galleryPage2GalleryPageInfo);
    } on DioException catch (e) {
      /// handle with domain fronting, manually load more
      if (e.response?.statusCode == 403 && e.response!.redirects.isNotEmpty) {
        return loadMore(checkLoadingState: false);
      }

      log.error('change favorite sort order fail', e.message);
      snack('failed'.tr, e.message ?? '');
      state.loadingState = LoadingState.error;
      updateSafely([loadingStateId]);
      return;
    } on EHSiteException catch (e) {
      log.error('change favorite sort order fail', e.message);
      snack('failed'.tr, e.message);
      state.loadingState = LoadingState.error;
      updateSafely([loadingStateId]);
      return;
    }

    return loadMore(checkLoadingState: false);
  }

  @override
  Future<void> saveSearchConfig(SearchConfig searchConfig) async {
    await localConfigService.write(
      configKey: ConfigEnum.searchConfig,
      subConfigKey: searchConfigKey,
      value: jsonEncode(searchConfig.copyWith(keyword: '', tags: [])),
    );
  }
}
