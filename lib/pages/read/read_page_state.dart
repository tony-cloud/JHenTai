import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/mixin/scroll_status_listener_state.dart';
import 'package:jhentai/model/read_page_info.dart';
import 'package:jhentai/setting/site_setting.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'package:jhentai/model/gallery_image.dart';
import 'package:jhentai/model/gallery_thumbnail.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/setting/read_setting.dart';
import 'package:jhentai/widget/loading_state_indicator.dart';

class ReadPageState with ScrollStatusListerState {
  /// gallery info
  final ReadPageInfo readPageInfo = Get.arguments;

  /// property used for parsing and loading
  int thumbnailsCountPerPage = SiteSetting.thumbnailsCountPerPage.value;
  late List<GalleryThumbnail?> thumbnails;
  late List<GalleryImage?> images;

  late List<LoadingState> parseImageHrefsStates;
  late List<LoadingState> parseImageUrlStates;
  late List<Size?> imageContainerSizes;
  String? parseImageHrefErrorMsg;
  late List<String?> parseImageUrlErrorMsg;

  bool autoMode = false;
  bool isMenuOpen = false;
  Battery? battery;
  int batteryLevel = 100;
  bool useSuperResolution = false;
  bool displayFirstPageAlone = readSetting.displayFirstPageAlone.value;
  FocusNode focusNode = FocusNode();

  late Size displayRegionSize;

  final ItemPositionsListener thumbnailPositionsListener = ItemPositionsListener.create();
  final ItemScrollController thumbnailsScrollController = ItemScrollController();
  final ScrollOffsetController thumbnailsScrollOffsetController = ScrollOffsetController();

  ReadPageState() {
    if (GetPlatform.isMobile) {
      battery = Battery();
    }

    thumbnails = List.generate(readPageInfo.pageCount, (_) => null, growable: true);

    if (readPageInfo.mode == ReadMode.online) {
      images = List.generate(readPageInfo.pageCount, (_) => null);
    }

    if (readPageInfo.mode == ReadMode.downloaded && readPageInfo.images != null) {
      images = readPageInfo.images!.cast<GalleryImage?>();
    }

    if (readPageInfo.mode == ReadMode.downloaded && readPageInfo.images == null) {
      images = galleryDownloadService.galleryDownloadInfos[readPageInfo.gid]!.images;
    }

    if (readPageInfo.mode == ReadMode.archive || readPageInfo.mode == ReadMode.local) {
      images = readPageInfo.images!.cast<GalleryImage?>();
    }

    parseImageHrefsStates = List.generate(readPageInfo.pageCount, (_) => LoadingState.idle);
    parseImageUrlStates = List.generate(readPageInfo.pageCount, (_) => LoadingState.idle);
    imageContainerSizes = List.generate(readPageInfo.pageCount, (_) => null);
    parseImageUrlErrorMsg = List.generate(readPageInfo.pageCount, (_) => null);
    parseImageUrlErrorMsg = List.generate(readPageInfo.pageCount, (_) => null);

    useSuperResolution = readPageInfo.useSuperResolution;
  }
}
