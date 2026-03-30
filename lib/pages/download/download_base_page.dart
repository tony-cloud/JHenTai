import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/enum/config_enum.dart';
import 'package:jhentai/extension/widget_extension.dart';
import 'package:jhentai/pages/download/grid/local/local_gallery_grid_page.dart';
import 'package:jhentai/service/local_config_service.dart';
import 'package:simple_animations/animation_controller_extension/animation_controller_extension.dart';
import 'package:simple_animations/animation_mixin/animation_mixin.dart';
import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/pages/download/grid/archive/archive_grid_download_page.dart';
import 'package:jhentai/pages/download/grid/gallery/gallery_grid_download_page.dart';
import 'package:jhentai/pages/download/list/archive/archive_list_download_page.dart';
import 'package:jhentai/pages/download/list/gallery/gallery_list_download_page.dart';
import 'package:jhentai/pages/download/list/local/local_gallery_list_page.dart';

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class DownloadPageArgument {
  final int? targetGalleryGid;
  final Duration focusHighlightDuration;

  const DownloadPageArgument({
    this.targetGalleryGid,
    this.focusHighlightDuration = const Duration(milliseconds: 1500),
  });
}

class DownloadPageFocusBridge {
  static DownloadPageArgument? _pendingArgument;

  static void setPendingArgument(DownloadPageArgument? argument) {
    _pendingArgument = argument;
  }

  static DownloadPageArgument? takePendingArgument() {
    final DownloadPageArgument? argument = _pendingArgument;
    _pendingArgument = null;
    return argument;
  }
}

class _DownloadPageState extends State<DownloadPage> {
  DownloadPageGalleryType galleryType = DownloadPageGalleryType.download;
  DownloadPageBodyType bodyType =
      GetPlatform.isMobile ? DownloadPageBodyType.list : DownloadPageBodyType.grid;
  Completer<void> bodyTypeCompleter = Completer<void>();

  int? focusGalleryGid;
  int? focusRequestId;
  Duration focusHighlightDuration = const Duration(milliseconds: 1500);

  @override
  void initState() {
    super.initState();

    _consumeFocusRequest();

    localConfigService.read(configKey: ConfigEnum.downloadPageBodyType).then((bodyTypeString) {
      if (bodyTypeString != null && focusGalleryGid == null) {
        bodyType = DownloadPageBodyType.values[int.tryParse(bodyTypeString) ?? 0];
      }
    }).whenComplete(() {
      bodyTypeCompleter.complete();
    });
  }

  @override
  void didUpdateWidget(covariant DownloadPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    _consumeFocusRequest(setStateIfNeeded: true);
  }

  void _consumeFocusRequest({bool setStateIfNeeded = false}) {
    DownloadPageArgument? argument;

    if (Get.arguments is DownloadPageArgument) {
      argument = Get.arguments;
      DownloadPageFocusBridge.setPendingArgument(null);
    } else {
      argument = DownloadPageFocusBridge.takePendingArgument();
    }

    if (argument?.targetGalleryGid == null) {
      return;
    }

    if (setStateIfNeeded) {
      setState(() {
        _applyFocusRequest(argument!);
      });
      return;
    }

    _applyFocusRequest(argument!);
  }

  void _applyFocusRequest(DownloadPageArgument argument) {
    focusGalleryGid = argument.targetGalleryGid;
    focusHighlightDuration = argument.focusHighlightDuration;

    galleryType = DownloadPageGalleryType.download;
    bodyType = DownloadPageBodyType.list;
    focusRequestId = DateTime.now().microsecondsSinceEpoch;
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      child: NotificationListener<DownloadPageBodyTypeChangeNotification>(
        onNotification: (DownloadPageBodyTypeChangeNotification notification) {
          setState(() {
            galleryType = notification.galleryType ?? galleryType;
            bodyType = notification.bodyType ?? bodyType;
          });
          localConfigService.write(
              configKey: ConfigEnum.downloadPageBodyType,
              value: (notification.bodyType ?? bodyType).index.toString());
          return true;
        },
        child: FutureBuilder(
          future: bodyTypeCompleter.future,
          builder: (_, __) => !bodyTypeCompleter.isCompleted
              ? const Center()
              : galleryType == DownloadPageGalleryType.download
                  ? bodyType == DownloadPageBodyType.list
                      ? GalleryListDownloadPage(
                          key: const PageStorageKey('GalleryListDownloadBody'),
                          focusGalleryGid: focusGalleryGid,
                          focusRequestId: focusRequestId,
                          focusHighlightDuration: focusHighlightDuration,
                        )
                      : GalleryGridDownloadPage(
                          key: const PageStorageKey('GalleryGridDownloadBody'))
                  : galleryType == DownloadPageGalleryType.archive
                      ? bodyType == DownloadPageBodyType.list
                          ? ArchiveListDownloadPage(
                              key: const PageStorageKey('ArchiveListDownloadBody'))
                          : ArchiveGridDownloadPage(
                              key: const PageStorageKey('ArchiveGridDownloadBody'))
                      : bodyType == DownloadPageBodyType.list
                          ? LocalGalleryListPage(key: const PageStorageKey('LocalGalleryListBody'))
                          : LocalGalleryGridPage(key: const PageStorageKey('LocalGalleryGridBody')),
        ),
      ),
    ).enableMouseDrag();
  }
}

enum DownloadPageGalleryType { download, archive, local }

enum DownloadPageBodyType { list, grid }

class DownloadPageBodyTypeChangeNotification extends Notification {
  DownloadPageGalleryType? galleryType;
  DownloadPageBodyType? bodyType;

  DownloadPageBodyTypeChangeNotification({this.galleryType, this.bodyType});
}

class DownloadPageSegmentControl extends StatelessWidget {
  final DownloadPageGalleryType galleryType;

  const DownloadPageSegmentControl({super.key, required this.galleryType});

  @override
  Widget build(BuildContext context) {
    return CupertinoSlidingSegmentedControl<DownloadPageGalleryType>(
      groupValue: galleryType,
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 3),
      children: {
        DownloadPageGalleryType.download: SizedBox(
          width: UIConfig.downloadPageSegmentedControlWidth,
          child: Center(
            child: Text(
              'download'.tr,
              style: const TextStyle(
                  fontSize: UIConfig.downloadPageSegmentedTextSize, fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        DownloadPageGalleryType.archive: Text(
          'archive'.tr,
          style: const TextStyle(
              fontSize: UIConfig.downloadPageSegmentedTextSize, fontWeight: FontWeight.bold),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        DownloadPageGalleryType.local: Text(
          'local'.tr,
          style: const TextStyle(
              fontSize: UIConfig.downloadPageSegmentedTextSize, fontWeight: FontWeight.bold),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      },
      onValueChanged: (value) =>
          DownloadPageBodyTypeChangeNotification(galleryType: value!).dispatch(context),
    );
  }
}

class GroupOpenIndicator extends StatefulWidget {
  final bool isOpen;

  const GroupOpenIndicator({super.key, required this.isOpen});

  @override
  State<GroupOpenIndicator> createState() => _GroupOpenIndicatorState();
}

class _GroupOpenIndicatorState extends State<GroupOpenIndicator> with AnimationMixin {
  bool isOpen = false;
  late Animation<double> animation = Tween<double>(begin: 0.0, end: -0.25).animate(controller);

  @override
  void initState() {
    super.initState();

    isOpen = widget.isOpen;
    if (isOpen) {
      controller.forward(from: 1);
    }
  }

  @override
  void didUpdateWidget(covariant GroupOpenIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.isOpen == widget.isOpen) {
      return;
    }

    isOpen = widget.isOpen;
    if (isOpen) {
      controller.play(duration: const Duration(milliseconds: 150));
    } else {
      controller.playReverse(duration: const Duration(milliseconds: 150));
    }
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: animation,
      child: const Icon(Icons.keyboard_arrow_left),
    );
  }
}
