import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/exception/eh_site_exception.dart';
import 'package:jhentai/extension/dio_exception_extension.dart';
import 'package:jhentai/extension/get_logic_extension.dart';
import 'package:jhentai/model/gallery.dart';
import 'package:jhentai/model/gallery_page.dart';
import 'package:jhentai/model/search_config.dart';
import 'package:jhentai/network/eh_request.dart';
import 'package:jhentai/network/rpc_request.dart';
import 'package:jhentai/pages/base/base_page_logic.dart';
import 'package:jhentai/pages/base/multi_select/multi_select_gallery_logic_mixin.dart';
import 'package:jhentai/pages/base/multi_select/multi_select_gallery_state_mixin.dart';
import 'package:jhentai/pages/favorite/favorite_page_state.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/service/local_config_service.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/utils/eh_spider_parser.dart';
import 'package:jhentai/utils/snack_util.dart';
import 'package:jhentai/widget/eh_favorite_sort_order_dialog.dart';
import 'package:jhentai/widget/loading_state_indicator.dart';

class FavoritePageLogic extends BasePageLogic with MultiSelectGalleryLogicMixin {
  CancelToken? _downloadAndUpdateAllCancelToken;
  bool _isCollectingDownloadAndUpdateAll = false;

  @override
  bool get useSearchConfig => true;

  @override
  bool get autoLoadNeedLogin => true;

  @override
  final FavoritePageState state = FavoritePageState();

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
      await ehRequest.requestChangeFavoriteSortOrder(
        result,
        parser: EHSpiderParser.galleryPage2GalleryPageInfo,
      );
    } on DioException catch (e) {
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

  Future<void> handleDownloadAndUpdateAllCurrentFavcat() async {
    if (isHandlingBatchDownloadAndUpdate || _isCollectingDownloadAndUpdateAll) {
      snack('failed'.tr, 'downloadAndUpdateBusy'.tr, isShort: true);
      return;
    }

    final config = await showBatchDownloadAndUpdateDialog();

    if (config == null) {
      return;
    }

    _isCollectingDownloadAndUpdateAll = true;
    _downloadAndUpdateAllCancelToken?.cancel();
    _downloadAndUpdateAllCancelToken = CancelToken();

    try {
      if (useRpcBatchDownloadAndUpdate) {
        final Map<String, dynamic> result = await rpcRequest.requestDownloadGalleryBatchFavorite(
          searchConfig: state.searchConfig.toJson(),
          config: buildBatchDownloadConfigPayload(config),
          cancelToken: _downloadAndUpdateAllCancelToken,
        );

        await galleryDownloadService.refreshRemoteGallerys();

        showBatchDownloadAndUpdateResult(
          queuedDownloadCount: (result['queuedDownloadCount'] as num? ?? 0).toInt(),
          updateQueuedCount: (result['updateQueuedCount'] as num? ?? 0).toInt(),
          failedCount: (result['failedCount'] as num? ?? 0).toInt(),
          aborted: result['aborted'] == true,
        );
        return;
      }

      final List<Gallery> gallerys = await _collectCurrentFavcatGallerys(
        _downloadAndUpdateAllCancelToken!,
      );

      if (gallerys.isEmpty) {
        snack('noData'.tr, '', isShort: true);
        return;
      }

      await runBatchDownloadAndUpdate(gallerys, config: config);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        return;
      }

      log.error('refreshGalleryFailed'.tr, e.errorMsg);
      snack('failed'.tr, e.errorMsg ?? '', isShort: true);
    } on RPCRequestException catch (e) {
      if (e.code == -32041) {
        snack('failed'.tr, 'downloadAndUpdateBusy'.tr, isShort: true);
        return;
      }

      log.error('refreshGalleryFailed'.tr, e.message);
      snack('failed'.tr, e.message, isShort: true);
    } on EHSiteException catch (e) {
      log.error('refreshGalleryFailed'.tr, e.message);
      snack('failed'.tr, e.message, isShort: true);
    } finally {
      _isCollectingDownloadAndUpdateAll = false;
      _downloadAndUpdateAllCancelToken = null;
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

  Future<List<Gallery>> _collectCurrentFavcatGallerys(
    CancelToken cancelToken,
  ) async {
    final SearchConfig searchConfig = SearchConfig.fromJson(state.searchConfig.toJson());
    final List<Gallery> gallerys = <Gallery>[];
    final Set<int> handledGids = <int>{};
    String? nextGid;

    while (true) {
      final GalleryPageInfo pageInfo = await ehRequest.requestGalleryPage(
        nextGid: nextGid,
        searchConfig: searchConfig,
        cancelToken: cancelToken,
        parser: EHSpiderParser.galleryPage2GalleryPageInfo,
      );

      for (final Gallery gallery in pageInfo.gallerys) {
        if (handledGids.add(gallery.gid)) {
          gallerys.add(gallery);
        }
      }

      if (pageInfo.nextGid == null) {
        return gallerys;
      }

      nextGid = pageInfo.nextGid;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  @override
  void onClose() {
    if (useRpcBatchDownloadAndUpdate && _isCollectingDownloadAndUpdateAll) {
      unawaited(rpcRequest.requestDownloadGalleryBatchAbort());
    }

    _downloadAndUpdateAllCancelToken?.cancel();
    super.onClose();
  }
}
