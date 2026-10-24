import 'package:flutter/material.dart';

import 'package:blur/blur.dart';
import 'package:extended_image/extended_image.dart';
import 'package:get/get.dart';

import 'package:jhentai/config/ui_config.dart';
import 'package:jhentai/utils/domain_fronting_util.dart';
import 'package:jhentai/widget/eh_image_request_builder.dart';

class EHWarningImage extends StatefulWidget {
  final bool warning;
  final String src;

  const EHWarningImage({super.key, required this.warning, required this.src});

  @override
  State<EHWarningImage> createState() => _EHWarningImageState();
}

class _EHWarningImageState extends State<EHWarningImage> {
  bool warning = false;

  @override
  void initState() {
    warning = widget.warning;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return EHImageRequestBuilder(
      url: widget.src,
      loadingBuilder: (context) => Center(child: UIConfig.loadingAnimation(context)),
      builder: (context, fronting, headers, retry) => GestureDetector(
        onTap: () {
          if (warning) {
            setState(() => warning = false);
          }
        },
        child: warning
            ? Blur(
                blur: 15,
                blurColor: UIConfig.warningImageBlurColor,
                colorOpacity: 0.75,
                overlay: Center(
                  child: Text(
                    'warningImageHint'.tr,
                    style: const TextStyle(
                        fontSize: 12, height: 2, color: UIConfig.warningImageTextColor),
                    textAlign: TextAlign.center,
                  ),
                ),
                child: _buildImage(fronting, headers, retry),
              )
            : _buildImage(fronting, headers, retry),
      ),
    );
  }

  Widget _buildImage(
    DomainFrontingResult fronting,
    Map<String, String>? headers,
    VoidCallback retry,
  ) {
    return ExtendedImage.network(
      fronting.url,
      headers: headers,
      loadStateChanged: (state) {
        if (state.extendedImageLoadState != LoadState.failed) {
          return null;
        }
        DomainFrontingUtil.markUnavailableFromResult(fronting);
        return Center(
          child: GestureDetector(
            onTap: retry,
            child: const Icon(Icons.sentiment_very_dissatisfied),
          ),
        );
      },
    );
  }
}
