import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/model/read_page_info.dart';
import 'package:jhentai/widget/eh_wheel_scroll_listener.dart';

import '../../../../setting/read_setting.dart';
import '../../../../widget/photo_view/j_photo_view_gallery.dart';
import '../base/base_layout.dart';
import 'horizontal_page_layout_logic.dart';
import 'horizontal_page_layout_state.dart';

class HorizontalPageLayout extends BaseLayout {
  HorizontalPageLayout({super.key});

  @override
  final HorizontalPageLayoutLogic logic =
      Get.put<HorizontalPageLayoutLogic>(HorizontalPageLayoutLogic(), permanent: true);

  final HorizontalPageLayoutState state = Get.find<HorizontalPageLayoutLogic>().state;

  @override
  Widget buildBody(BuildContext context) {
    return EHWheelListener(
      onPointerScroll: readSetting.isInFitWidthReadDirection ? null : logic.onPointerScroll,
      child: JPhotoViewGallery.builder(
        itemCount: readPageState.readPageInfo.pageCount,
        scrollPhysics: const ClampingScrollPhysics(),
        pageController: logic.pageController,
        reverse: readSetting.isInRight2LeftDirection,
        builder: (context, index) => JPhotoViewGalleryPageOptions.customChild(
          initialScale: 1.0,
          minScale: 1.0,
          maxScale: 2.5,
          scaleStateCycle:
              readSetting.enableDoubleTapToScaleUp.isTrue ? logic.scaleStateCycle : null,
          enableTapDragZoom: readSetting.enableTapDragToScaleUp.isTrue,
          child: Obx(() {
            Widget item = readPageState.readPageInfo.mode == ReadMode.online
                ? buildItemInOnlineMode(context, index)
                : buildItemInLocalMode(context, index);

            if (readSetting.isInFitWidthReadDirection) {
              item =
                  Center(child: SingleChildScrollView(controller: ScrollController(), child: item));
            }

            return item;
          }),
        ),
      ),
    );
  }
}
