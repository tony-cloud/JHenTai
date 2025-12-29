import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/extension/widget_extension.dart';
import 'package:jhentai/mixin/window_widget_mixin.dart';
import 'package:jhentai/mixin/scroll_status_listener.dart';
import 'package:jhentai/mixin/scroll_status_listener_state.dart';
import 'package:jhentai/model/read_page_info.dart';
import 'package:jhentai/pages/read/layout/horizontal_list/horizontal_list_layout.dart';
import 'package:jhentai/pages/read/layout/horizontal_page/horizontal_page_layout.dart';
import 'package:jhentai/pages/read/read_page_logic.dart';
import 'package:jhentai/pages/read/read_page_state.dart';
import 'package:jhentai/service/super_resolution_service.dart';
import 'package:jhentai/widget/eh_mouse_button_listener.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:window_manager/window_manager.dart';

import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/routes/routes.dart';
import 'package:jhentai/service/gallery_download_service.dart';
import 'package:jhentai/setting/read_setting.dart';
import 'package:jhentai/utils/route_util.dart';
import 'package:jhentai/utils/screen_size_util.dart';
import 'package:jhentai/utils/toast_util.dart';
import 'package:jhentai/widget/eh_image.dart';
import 'package:jhentai/widget/eh_keyboard_listener.dart';
import 'package:jhentai/widget/eh_read_page_stack.dart';
import 'package:jhentai/widget/eh_thumbnail.dart';
import 'package:jhentai/widget/eh_wheel_speed_controller_for_read_page.dart';
import 'package:jhentai/widget/loading_state_indicator.dart';
import 'package:jhentai/pages/home_page.dart';
import 'package:jhentai/pages/read/layout/horizontal_double_column/horizontal_double_column_layout.dart';
import 'package:jhentai/pages/read/layout/vertical_list/vertical_list_layout.dart';

class ReadPage extends StatefulWidget {
  const ReadPage({super.key});

  @override
  State<ReadPage> createState() => _ReadPageState();
}

class _ReadTapRegions extends StatefulWidget {
  const _ReadTapRegions({
    required this.centerRegionRatio,
    required this.onTapLeft,
    required this.onTapCenter,
    required this.onTapRight,
  });

  final double centerRegionRatio;
  final VoidCallback onTapLeft;
  final VoidCallback onTapCenter;
  final VoidCallback onTapRight;

  @override
  State<_ReadTapRegions> createState() => _ReadTapRegionsState();
}

class _ReadTapRegionsState extends State<_ReadTapRegions> {
  final Map<int, _PointerTracker> _activePointers = {};

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerCancel: _handlePointerCancel,
      onPointerUp: _handlePointerUp,
      child: const SizedBox.expand(),
    );
  }

  void _handlePointerDown(PointerDownEvent event) {
    _activePointers[event.pointer] = _PointerTracker(
      initialPosition: event.localPosition,
    );

    if (_activePointers.length > 1) {
      for (final tracker in _activePointers.values) {
        tracker.hasExceededSlop = true;
      }
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final tracker = _activePointers[event.pointer];
    if (tracker == null) {
      return;
    }

    if (!tracker.hasExceededSlop) {
      final Offset delta = event.localPosition - tracker.initialPosition;
      if (delta.distance > kTouchSlop) {
        tracker.hasExceededSlop = true;
      }
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
  }

  void _handlePointerUp(PointerUpEvent event) {
    final tracker = _activePointers.remove(event.pointer);
    if (tracker == null) {
      return;
    }

    if (tracker.hasExceededSlop) {
      return;
    }

    _dispatchTap(event.localPosition);
  }

  void _dispatchTap(Offset localPosition) {
    final Size? size = context.size;
    if (size == null || size.width == 0) {
      return;
    }

    final double ratio = widget.centerRegionRatio.clamp(0.0, 1.0);
    final double centerWidth = size.width * ratio;
    final double sideWidth = (size.width - centerWidth) / 2;

    if (localPosition.dx < sideWidth) {
      widget.onTapLeft();
      return;
    }

    if (localPosition.dx > size.width - sideWidth) {
      widget.onTapRight();
      return;
    }

    widget.onTapCenter();
  }
}

class _PointerTracker {
  _PointerTracker({required this.initialPosition});

  final Offset initialPosition;
  bool hasExceededSlop = false;
}

class _ReadPageState extends State<ReadPage>
    with ScrollStatusListener, WindowListener, WindowWidgetMixin {
  final ReadPageLogic logic = Get.put<ReadPageLogic>(ReadPageLogic());
  final ReadPageState state = Get.find<ReadPageLogic>().state;

  @override
  ScrollStatusListerState get scrollStatusListerState => state;

  @override
  Brightness? get titleBarBrightness => Brightness.dark;

  @override
  Color? get titleBarColor => Colors.black;

  @override
  double get fullScreenTopPadding => 0;

  @override
  Widget build(BuildContext context) {
    Widget child = AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        statusBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: EHMouseButtonListener(
        onFifthButtonTapDown: (_) => backRoute(),
        child: EHKeyboardListener(
          focusNode: state.focusNode,
          handleEsc: backRoute,
          handleSpace: logic.toggleMenu,
          handlePageDown: logic.toNext,
          handlePageUp: logic.toPrev,
          handleArrowDown: logic.toNext,
          handleArrowUp: logic.toPrev,
          handleArrowRight: logic.toRight,
          handleArrowLeft: logic.toLeft,
          handleA: logic.toLeft,
          handleD: logic.toRight,
          handleM: logic.handleM,
          handleEnd: backRoute,
          handleF11: toggleFullScreen,
          child: DefaultTextStyle(
            style: DefaultTextStyle.of(context).style.copyWith(
                  color: UIConfig.readPageForeGroundColor,
                  fontSize: 12,
                  decoration: TextDecoration.none,
                ),
            child: Container(
              color: Colors.black,
              child: Stack(
                children: [
                  EHReadPageStack(
                    children: [
                      buildGestureRegion(),
                      buildLayout(),
                    ],
                  ),
                  buildRightBottomInfo(context),
                  buildTopMenu(context),
                  buildBottomMenu(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    return GetBuilder<ReadPageLogic>(
      id: logic.pageId,
      builder: (_) {
        if (readSetting.enableImmersiveMode.isFalse) {
          return buildWindow(child: child);
        }
        return child;
      },
    );
  }

  @override
  Widget buildWindow({required Widget child}) {
    return GetPlatform.isWindows
        ? buildWindowsTitle(child)
        : GetPlatform.isLinux
            ? buildLinuxTitle(child)
            : GetPlatform.isMacOS
                ? buildMaxOSTitle(child)
                : child;
  }

  /// Main region to display images
  Widget buildLayout() {
    Widget child = GetBuilder<ReadPageLogic>(
      id: logic.layoutId,
      builder: (_) {
        return LayoutBuilder(
          builder: (context, constraints) {
            logic.clearImageContainerSized();
            state.displayRegionSize = Size(constraints.maxWidth, constraints.maxHeight);

            if (readSetting.readDirection.value == ReadDirection.top2bottomList) {
              return VerticalListLayout();
            }
            if (readSetting.isInListReadDirection) {
              return HorizontalListLayout();
            }
            if (readSetting.isInDoubleColumnReadDirection) {
              return HorizontalDoubleColumnLayout();
            }
            return HorizontalPageLayout();
          },
        );
      },
    );

    return wrapScrollListener(child);
  }

  /// right-bottom info
  Widget buildRightBottomInfo(BuildContext context) {
    return Positioned(
      bottom: 0,
      right: 0,
      child: Obx(
        () {
          if (readSetting.showStatusInfo.isFalse) {
            return const SizedBox();
          }

          Widget child = DefaultTextStyle(
            style: DefaultTextStyle.of(context).style.copyWith(
                  color: UIConfig.readPageForeGroundColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  decoration: TextDecoration.none,
                ),
            child: Container(
              decoration: BoxDecoration(
                color: UIConfig.readPageRightBottomRegionColor,
                borderRadius: const BorderRadius.only(topLeft: Radius.circular(8)),
              ),
              alignment: Alignment.center,
              padding: const EdgeInsets.only(right: 32, bottom: 1, top: 3, left: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildPageNoInfo().marginOnly(right: 10),
                  _buildCurrentTime().marginOnly(right: 10),
                  if (!GetPlatform.isDesktop) _buildBatteryLevel(),
                ],
              ),
            ),
          );

          return GetBuilder<ReadPageLogic>(
            id: logic.rightBottomInfoId,
            builder: (_) => state.isMenuOpen ? child.fadeOutWidget() : child.fadeInWidget(),
          );
        },
      ),
    );
  }

  Widget _buildPageNoInfo() {
    return GetBuilder<ReadPageLogic>(
      id: logic.pageNoId,
      builder: (_) =>
          Text('${state.readPageInfo.currentImageIndex + 1}/${state.readPageInfo.pageCount}'),
    );
  }

  Widget _buildCurrentTime() {
    return GetBuilder<ReadPageLogic>(
      id: logic.currentTimeId,
      builder: (_) => Text(DateFormat('HH:mm').format(DateTime.now())),
    );
  }

  Widget _buildBatteryLevel() {
    return GetBuilder<ReadPageLogic>(
      id: logic.batteryId,
      builder: (_) => Text('${state.batteryLevel}%'),
    );
  }

  /// gesture for turn page and pop menu
  Widget buildGestureRegion() {
    return Obx(() {
      return _ReadTapRegions(
        centerRegionRatio: readSetting.gestureRegionWidthRatio.value / 100,
        onTapLeft: logic.tapLeftRegion,
        onTapCenter: logic.tapCenterRegion,
        onTapRight: logic.tapRightRegion,
      );
    });
  }

  /// top menu
  Widget buildTopMenu(BuildContext context) {
    return GetBuilder<ReadPageLogic>(
      id: logic.topMenuId,
      builder: (_) => AnimatedPositioned(
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
        height: state.isMenuOpen ? UIConfig.appBarHeight + context.mediaQuery.padding.top : 0,
        width: fullScreenWidth,
        child: AppBar(
          backgroundColor: UIConfig.readPageMenuColor,
          leading: const BackButton(color: UIConfig.readPageButtonColor),
          actions: [
            if (GetPlatform.isDesktop)
              ElevatedButton(
                onPressed: () => toast(
                  'PageDown、→、↓ 、D :  ${'toNext'.tr}'
                  '\n'
                  'PageUp、←、↑、A  :  ${'toPrev'.tr}'
                  '\n'
                  'Esc、End  :  ${'back'.tr}'
                  '\n'
                  'Space  :  ${'toggleMenu'.tr}'
                  '\n'
                  'M  :  ${'displayFirstPageAlone'.tr}'
                  '\n'
                  'F11  :  ${'toggleFullScreen'.tr}',
                  isShort: false,
                ),
                style: ElevatedButton.styleFrom(
                  elevation: 0,
                  padding: const EdgeInsets.all(0),
                  surfaceTintColor: Colors.transparent,
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  minimumSize: const Size(56, 56),
                ),
                child: const Icon(Icons.help, color: UIConfig.readPageButtonColor),
              ),
            if (GetPlatform.isDesktop &&
                state.readPageInfo.gid != null &&
                (state.readPageInfo.mode == ReadMode.downloaded ||
                    state.readPageInfo.mode == ReadMode.archive) &&
                state.readPageInfo.useSuperResolution)
              TextButton(
                onPressed: logic.handleTapSuperResolutionButton,
                style: TextButton.styleFrom(
                  minimumSize: const Size(56, 56),
                ),
                child: GetBuilder<SuperResolutionService>(
                  id: '${SuperResolutionService.superResolutionId}::${state.readPageInfo.gid}',
                  builder: (_) => Text(
                    'AI${logic.getSuperResolutionProgress()}',
                    style: TextStyle(
                      fontSize: 18,
                      color: state.useSuperResolution
                          ? UIConfig.readPageActiveButtonColor(context)
                          : UIConfig.readPageButtonColor,
                    ),
                  ),
                ),
              ),
            Obx(() {
              if (!readSetting.isInDoubleColumnReadDirection) {
                return const SizedBox();
              }
              return ElevatedButton(
                onPressed: logic.toggleDisplayFirstPageAlone,
                style: ElevatedButton.styleFrom(
                  elevation: 0,
                  padding: const EdgeInsets.all(0),
                  surfaceTintColor: Colors.transparent,
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  minimumSize: const Size(56, 56),
                ),
                child: Icon(
                  Icons.looks_one,
                  color: state.displayFirstPageAlone
                      ? UIConfig.readPageActiveButtonColor(context)
                      : UIConfig.readPageButtonColor,
                ),
              );
            }),
            GetBuilder<ReadPageLogic>(
              id: logic.autoModeId,
              builder: (_) => ElevatedButton(
                onPressed: logic.toggleAutoMode,
                style: ElevatedButton.styleFrom(
                  elevation: 0,
                  padding: const EdgeInsets.all(0),
                  surfaceTintColor: Colors.transparent,
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  minimumSize: const Size(56, 56),
                ),
                child: Icon(Icons.schedule,
                    color: state.autoMode
                        ? UIConfig.readPageActiveButtonColor(context)
                        : UIConfig.readPageButtonColor),
              ),
            ),
            if (readSetting.enableBottomMenu.isFalse)
              ElevatedButton(
                onPressed: () {
                  logic.restoreImmersiveMode();
                  toRoute(Routes.settingRead, id: fullScreen)?.then((_) {
                    logic.applyCurrentImmersiveMode();
                    state.focusNode.requestFocus();
                  });
                },
                style: ElevatedButton.styleFrom(
                  elevation: 0,
                  padding: const EdgeInsets.all(0),
                  surfaceTintColor: Colors.transparent,
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  minimumSize: const Size(56, 56),
                ),
                child: const Icon(Icons.settings, color: UIConfig.readPageButtonColor),
              ),
          ],
        ),
      ),
    );
  }

  /// bottom menu
  Widget buildBottomMenu(BuildContext context) {
    return GetBuilder<ReadPageLogic>(
      id: logic.bottomMenuId,
      builder: (_) => Obx(
        () => AnimatedPositioned(
          duration: const Duration(milliseconds: 200),
          curve: Curves.ease,
          bottom: state.isMenuOpen
              ? 0
              : (readSetting.showThumbnails.isTrue
                      ? -UIConfig.readPageBottomThumbnailsRegionHeight
                      : 0) -
                  UIConfig.readPageBottomSliderHeight -
                  (readSetting.enableBottomMenu.isTrue ? UIConfig.readPageBottomActionHeight : 0) -
                  max(MediaQuery.of(context).viewPadding.bottom,
                      UIConfig.readPageBottomSpacingHeight),
          child: ColoredBox(
            color: UIConfig.readPageMenuColor,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (readSetting.showThumbnails.isTrue) _buildThumbnails(context),
                _buildSlider(),
                if (readSetting.enableBottomMenu.isTrue) _buildBottomAction(),
                SizedBox(
                    height: max(MediaQuery.of(context).viewPadding.bottom,
                        UIConfig.readPageBottomSpacingHeight)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnails(BuildContext context) {
    return SizedBox(
      width: fullScreenWidth,
      height: UIConfig.readPageBottomThumbnailsRegionHeight,
      child: Obx(
        () => EHWheelSpeedControllerForReadPage(
          scrollOffsetController: state.thumbnailsScrollOffsetController,
          child: ScrollablePositionedList.separated(
            scrollDirection: Axis.horizontal,
            reverse: readSetting.isInRight2LeftDirection,
            physics: const ClampingScrollPhysics(),
            minCacheExtent: 1 * fullScreenWidth,
            initialScrollIndex: state.readPageInfo.initialIndex,
            itemCount: state.readPageInfo.pageCount,
            itemScrollController: state.thumbnailsScrollController,
            itemPositionsListener: state.thumbnailPositionsListener,
            scrollOffsetController: state.thumbnailsScrollOffsetController,
            itemBuilder: (_, index) => GetBuilder<ReadPageLogic>(
              id: logic.thumbnailNoId,
              builder: (_) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 6),
                  SizedBox(
                    height: UIConfig.readPageThumbnailHeight,
                    width: UIConfig.readPageThumbnailWidth,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => logic.jump2ImageIndex(index),
                      child: state.readPageInfo.mode == ReadMode.online
                          ? _buildThumbnailInOnlineMode(context, index)
                          : _buildThumbnailInLocalMode(context, index),
                    ),
                  ),
                  const SizedBox(height: 4),
                  GetBuilder<ReadPageLogic>(
                    builder: (_) => Center(
                      child: Container(
                        width: 24,
                        decoration: BoxDecoration(
                          color: state.readPageInfo.currentImageIndex == index
                              ? UIConfig.readPageBottomCurrentImageHighlightBackgroundColor(context)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          (index + 1).toString(),
                          style: TextStyle(
                            fontSize: 9,
                            color: state.readPageInfo.currentImageIndex == index
                                ? UIConfig.readPageBottomCurrentImageHighlightForegroundColor(
                                    context)
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Expanded(child: SizedBox()),
                ],
              ),
            ),
            separatorBuilder: (_, __) => const SizedBox(width: 6),
          ),
        ).enableMouseDrag(withScrollBar: false),
      ),
    );
  }

  Widget _buildThumbnailInOnlineMode(BuildContext context, int index) {
    return GetBuilder<ReadPageLogic>(
      id: '${logic.onlineImageId}::$index',
      builder: (_) {
        if (state.thumbnails[index] == null) {
          if (state.parseImageHrefsStates[index] == LoadingState.idle) {
            logic.beginToParseImageHref(index);
          }

          return Center(child: UIConfig.loadingAnimation(context));
        }

        return LayoutBuilder(
          builder: (_, constraints) => EHThumbnail(
            thumbnail: state.thumbnails[index]!,
            containerHeight: constraints.maxHeight,
            containerWidth: constraints.maxWidth,
            borderRadius: BorderRadius.circular(8),
          ),
        );
      },
    );
  }

  Widget _buildThumbnailInLocalMode(BuildContext context, int index) {
    return GetBuilder<GalleryDownloadService>(
      id: '${galleryDownloadService.downloadImageId}::${state.readPageInfo.gid}::$index',
      builder: (_) {
        if (state.images[index]?.downloadStatus != DownloadStatus.downloaded) {
          return Center(child: UIConfig.loadingAnimation(context));
        }
        return LayoutBuilder(
          builder: (_, constraints) => EHImage(
            galleryImage: state.images[index]!,
            containerHeight: constraints.maxHeight,
            containerWidth: constraints.maxWidth,
            borderRadius: BorderRadius.circular(8),
            maxBytes: 1024 * 50,
          ),
        );
      },
    );
  }

  Widget _buildSlider() {
    return GetBuilder<ReadPageLogic>(
      id: logic.sliderId,
      builder: (_) => SizedBox(
        height: UIConfig.readPageBottomSliderHeight,
        width: fullScreenWidth,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(readSetting.isInRight2LeftDirection
                    ? state.readPageInfo.pageCount.toString()
                    : (state.readPageInfo.currentImageIndex + 1).toString())
                .marginOnly(left: 36, right: 4),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ExcludeFocus(
                    child: Material(
                      color: Colors.transparent,
                      child: RotatedBox(
                        quarterTurns: readSetting.isInRight2LeftDirection ? 2 : 0,
                        child: Slider(
                          min: 1,
                          max: state.readPageInfo.pageCount.toDouble(),
                          value: state.readPageInfo.currentImageIndex + 1.0,
                          thumbColor: UIConfig.readPageForeGroundColor,
                          onChanged: logic.handleSlide,
                          onChangeEnd: logic.handleSlideEnd,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Text(readSetting.isInRight2LeftDirection
                    ? (state.readPageInfo.currentImageIndex + 1).toString()
                    : state.readPageInfo.pageCount.toString())
                .marginOnly(right: 36, left: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomAction() {
    return SizedBox(
      height: UIConfig.readPageBottomActionHeight,
      width: fullScreenWidth,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Material(
            color: Colors.transparent,
            child: PopupMenuButton<ReadDirection>(
              initialValue: readSetting.readDirection.value,
              icon: const Icon(Icons.height, color: UIConfig.readPageButtonColor),
              itemBuilder: (_) => ReadDirection.values
                  .map(
                    (e) => PopupMenuItem<ReadDirection>(value: e, child: Text(e.name.tr)),
                  )
                  .toList(),
              onSelected: (ReadDirection value) => readSetting.saveReadDirection(value),
            ),
          ),
          Material(
            color: Colors.transparent,
            child: PopupMenuButton<DeviceDirection>(
              initialValue: readSetting.deviceDirection.value,
              icon: const Icon(Icons.screen_rotation, color: UIConfig.readPageButtonColor),
              itemBuilder: (_) => DeviceDirection.values
                  .map(
                    (e) => PopupMenuItem<DeviceDirection>(value: e, child: Text(e.name.tr)),
                  )
                  .toList(),
              onSelected: (DeviceDirection value) => readSetting.saveDeviceDirection(value),
            ),
          ),
          GestureDetector(
            child: AbsorbPointer(
              child: Material(
                color: Colors.transparent,
                child: PopupMenuButton(
                  icon: const Icon(Icons.settings, color: UIConfig.readPageButtonColor),
                  itemBuilder: (_) => [],
                ),
              ),
            ),
            onTap: () {
              logic.restoreImmersiveMode();
              toRoute(Routes.settingRead, id: fullScreen)?.then((_) {
                logic.applyCurrentImmersiveMode();
                state.focusNode.requestFocus();
              });
            },
          ),
        ],
      ),
    );
  }
}
