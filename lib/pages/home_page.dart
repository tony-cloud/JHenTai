import 'dart:async';

import 'package:clipboard/clipboard.dart';
import 'package:clipboard_detect/clipboard_detect.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:jhentai/consts/eh_consts.dart';
import 'package:jhentai/model/gallery_image_page_url.dart';
import 'package:jhentai/model/gallery_url.dart';
import 'package:jhentai/pages/details/details_page_logic.dart';
import 'package:jhentai/pages/gallery_image/gallery_image_page_logic.dart';
import 'package:jhentai/pages/layout/desktop/desktop_layout_page.dart';
import 'package:jhentai/pages/layout/mobile_v2/mobile_layout_page_v2.dart';
import 'package:jhentai/pages/layout/tablet_v2/tablet_layout_page_v2.dart';
import 'package:jhentai/setting/style_setting.dart';
import 'package:jhentai/setting/user_setting.dart';
import 'package:jhentai/service/log.dart';
import 'package:jhentai/utils/toast_util.dart';
import 'package:listen_sharing_intent/listen_sharing_intent.dart';
import 'package:window_manager/window_manager.dart';

import '../mixin/window_widget_mixin.dart';
import '../mixin/login_required_logic_mixin.dart';
import '../model/jh_layout.dart';
import '../routes/routes.dart';
import '../setting/advanced_setting.dart';
import '../utils/route_util.dart';
import '../utils/screen_size_util.dart';
import '../utils/snack_util.dart';

const int left = 1;
const int right = 2;
const int fullScreen = 3;
const int leftV2 = 4;
const int rightV2 = 5;

Routing leftRouting = Routing();
Routing rightRouting = Routing();

/// Core widget to decide which layout to be applied
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with LoginRequiredMixin, WindowListener, WindowWidgetMixin {
  StreamSubscription? _intentDataStreamSubscription;
  String? _lastDetectedText;
  final ClipboardDetect _clipboardDetect = ClipboardDetect();
  static final Set<String> _allowedClipboardHosts = <String>{
    Uri.parse(EHConsts.EHIndex).host,
    Uri.parse(EHConsts.EXIndex).host,
  };
  static const List<String> _urlDetectionPatterns = <String>['probableWebURL'];
  static const List<int> _primaryClipboardItem = <int>[0];

  late final AppLifecycleListener _listener;

  @override
  void initState() {
    super.initState();
    initToast(context);
    _initSharingIntent();
    _handleUrlInClipBoard();

    _listener = AppLifecycleListener(onResume: _handleUrlInClipBoard);
  }

  @override
  void dispose() {
    super.dispose();
    _intentDataStreamSubscription?.cancel();
    _listener.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return buildWindow(
      child: LayoutBuilder(
        builder: (_, __) => Obx(
          () {
            if (styleSetting.layout.value == LayoutMode.mobileV2 ||
                styleSetting.layout.value == LayoutMode.mobile) {
              styleSetting.actualLayout = LayoutMode.mobileV2;
              return MobileLayoutPageV2();
            }

            /// Device width is under 600, degrade to mobileV2 layout.
            if (fullScreenWidth < 600) {
              styleSetting.actualLayout = LayoutMode.mobileV2;
              untilRoute2BlankPage();
              return MobileLayoutPageV2();
            }

            if (styleSetting.layout.value == LayoutMode.tabletV2 ||
                styleSetting.layout.value == LayoutMode.tablet) {
              styleSetting.actualLayout = LayoutMode.tabletV2;
              return TabletLayoutPageV2();
            }

            styleSetting.actualLayout = LayoutMode.desktop;
            return DesktopLayoutPage();
          },
        ),
      ),
    );
  }

  /// Listen to share or open urls/text coming from outside the app while the app is in the memory or is closed
  void _initSharingIntent() {
    if (!GetPlatform.isAndroid) {
      return;
    }

    ReceiveSharingIntent.instance.getInitialMedia().then(
      (List<SharedMediaFile> files) {
        if (files.isEmpty) {
          return;
        }

        SharedMediaFile file = files.first;
        if (file.type != SharedMediaType.url && file.type != SharedMediaType.text) {
          return;
        }

        GalleryUrl? galleryUrl = GalleryUrl.tryParse(file.path);
        if (galleryUrl != null) {
          toRoute(
            Routes.details,
            arguments: DetailsPageArgument(galleryUrl: galleryUrl),
            offAllBefore: false,
            preventDuplicates: false,
          );
          return;
        }

        GalleryImagePageUrl? galleryImagePageUrl = GalleryImagePageUrl.tryParse(file.path);
        if (galleryImagePageUrl != null) {
          toRoute(
            Routes.imagePage,
            arguments: GalleryImagePageArgument(galleryImagePageUrl: galleryImagePageUrl),
            offAllBefore: false,
          );
          return;
        }

        toast('Invalid jump link', isShort: false);
      },
    ).whenComplete(() {
      ReceiveSharingIntent.instance.reset();
    });

    _intentDataStreamSubscription = ReceiveSharingIntent.instance.getMediaStream().listen(
      (List<SharedMediaFile> files) {
        if (files.isEmpty) {
          return;
        }

        SharedMediaFile file = files.first;
        if (file.type != SharedMediaType.url && file.type != SharedMediaType.text) {
          return;
        }

        GalleryUrl? galleryUrl = GalleryUrl.tryParse(file.path);
        if (galleryUrl != null) {
          untilRoute(
              currentRoute: Routes.details,
              predicate: (route) => route.settings.name != Routes.read);
          toRoute(
            Routes.details,
            arguments: DetailsPageArgument(galleryUrl: galleryUrl),
            offAllBefore: false,
            preventDuplicates: false,
          );
          return;
        }

        GalleryImagePageUrl? galleryImagePageUrl = GalleryImagePageUrl.tryParse(file.path);
        if (galleryImagePageUrl != null) {
          untilRoute(
              currentRoute: Routes.details,
              predicate: (route) => route.settings.name != Routes.read);
          toRoute(
            Routes.imagePage,
            arguments: GalleryImagePageArgument(galleryImagePageUrl: galleryImagePageUrl),
            offAllBefore: false,
          );
          return;
        }
      },
      onError: (e) {
        log.error('ReceiveSharingIntent Error!', e);
        log.uploadError(e);
      },
    );
  }

  /// a gallery url exists in clipboard, show dialog to check whether enter detail page
  void _handleUrlInClipBoard() async {
    if (advancedSetting.enableCheckClipboard.isFalse) {
      return;
    }

    String? clipboardText;

    if (GetPlatform.isIOS) {
      try {
        final List<Map<String, dynamic>> valueResults =
            await _clipboardDetect.detectClipboardValuesInItems(
          itemIndexes: _primaryClipboardItem,
          patterns: _urlDetectionPatterns,
        );

        final String? detectedText = _extractUrlFromValueResults(valueResults)?.trim();
        if (detectedText != null && detectedText.isNotEmpty) {
          if (!_clipboardMatchesEhDomains(detectedText)) {
            return;
          }
          clipboardText = detectedText;
        }
      } on PlatformException catch (error, stackTrace) {
        if (error.code != 'unsupported') {
          log.warning('Failed to detect clipboard values', error);
          log.uploadError(error, stackTrace: stackTrace);
          return;
        }
        // Fall back to direct clipboard access on unsupported iOS versions.
      } catch (error, stackTrace) {
        log.warning('Failed to detect clipboard values', error);
        log.uploadError(error, stackTrace: stackTrace);
        return;
      }
    }

    clipboardText ??= await _readClipboardText();
    if (clipboardText == null) {
      return;
    }

    final String sanitized = clipboardText.trim();
    if (sanitized.isEmpty) {
      return;
    }

    if (GetPlatform.isIOS && !_clipboardMatchesEhDomains(sanitized)) {
      return;
    }

    final GalleryUrl? galleryUrl = GalleryUrl.tryParse(sanitized);
    final GalleryImagePageUrl? galleryImagePageUrl = GalleryImagePageUrl.tryParse(sanitized);

    if (galleryUrl == null && galleryImagePageUrl == null) {
      return;
    }

    /// show snack only once
    if (sanitized == _lastDetectedText) {
      return;
    }

    _lastDetectedText = sanitized;
    if (galleryUrl != null) {
      snack(
        'galleryUrlDetected'.tr,
        '${'galleryUrlDetectedHint'.tr}: ${galleryUrl.url}',
        onPressed: () {
          if (!galleryUrl.isEH && !userSetting.hasLoggedIn()) {
            showLoginToast();
            return;
          }
          toRoute(
            Routes.details,
            arguments: DetailsPageArgument(galleryUrl: galleryUrl),
            offAllBefore: false,
            preventDuplicates: false,
          );
        },
        isShort: true,
      );
    } else if (galleryImagePageUrl != null) {
      snack(
        'galleryUrlDetected'.tr,
        '${'galleryUrlDetectedHint'.tr}: ${galleryImagePageUrl.url}',
        onPressed: () {
          if (!galleryImagePageUrl.isEH && !userSetting.hasLoggedIn()) {
            showLoginToast();
            return;
          }
          toRoute(
            Routes.imagePage,
            arguments: GalleryImagePageArgument(galleryImagePageUrl: galleryImagePageUrl),
            offAllBefore: false,
          );
        },
        isShort: true,
      );
    }
  }

  bool _clipboardMatchesEhDomains(String value) {
    final Uri? uri = _resolveUrl(value);
    if (uri == null) {
      return false;
    }

    return _allowedClipboardHosts.contains(uri.host.toLowerCase());
  }

  String? _extractUrlFromValueResults(List<Map<String, dynamic>> results) {
    for (final Map<String, dynamic> entry in results) {
      final dynamic rawValue = entry[_urlDetectionPatterns.first];
      if (rawValue is String && rawValue.trim().isNotEmpty) {
        return rawValue;
      }
    }
    return null;
  }

  Future<String?> _readClipboardText() async {
    try {
      return await FlutterClipboard.paste();
    } catch (error, stackTrace) {
      log.warning('Failed to read clipboard', error);
      log.uploadError(error, stackTrace: stackTrace);
      return null;
    }
  }

  Uri? _resolveUrl(String value) {
    final Uri? direct = Uri.tryParse(value);
    if (direct != null && direct.hasScheme && direct.host.isNotEmpty) {
      return direct;
    }

    final Uri? withScheme = Uri.tryParse('https://$value');
    if (withScheme != null && withScheme.host.isNotEmpty) {
      return withScheme;
    }

    return null;
  }
}
